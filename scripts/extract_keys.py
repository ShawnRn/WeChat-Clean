#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
微信 4.x 数据库与附件图片密钥提取器（macOS 专用，纯原生 Python + Mach VM / CommonCrypto）
支持提取：
1. SQLCipher 4 数据库密钥 (contact.db, session.db, message_x.db 等)
2. V2 .dat 图片 AES-128-ECB 解密密钥与 XOR 异或密钥
无需第三方依赖，可由 App 原生 Touch ID / Apple Watch 提权或终端一键执行。
"""

import sys
import os
import re
import json
import time
import ctypes
import hashlib
import hmac
import subprocess

PAGE_SZ = 4096
SALT_SZ = 16
RESERVE_SZ = 80
IV_SZ = 16
HMAC_SZ = 64
CHUNK_SIZE = 2 * 1024 * 1024 # 2MB

# Mach VM 定义
KERN_SUCCESS = 0
VM_PROT_READ = 1
VM_PROT_WRITE = 2
VM_REGION_BASIC_INFO_64 = 9

class VmRegionBasicInfo64(ctypes.Structure):
    _fields_ = [
        ("protection", ctypes.c_int32),
        ("max_protection", ctypes.c_int32),
        ("inheritance", ctypes.c_uint32),
        ("shared", ctypes.c_uint32),
        ("reserved", ctypes.c_uint32),
        ("offset", ctypes.c_uint64),
        ("behavior", ctypes.c_int32),
        ("user_wired_count", ctypes.c_uint16),
    ]

libc = ctypes.CDLL(None)
mach_task_self = libc.mach_task_self
mach_task_self.restype = ctypes.c_uint

task_for_pid = libc.task_for_pid
task_for_pid.argtypes = [ctypes.c_uint, ctypes.c_int, ctypes.POINTER(ctypes.c_uint)]
task_for_pid.restype = ctypes.c_int

mach_vm_region = libc.mach_vm_region
mach_vm_region.argtypes = [
    ctypes.c_uint,
    ctypes.POINTER(ctypes.c_uint64),
    ctypes.POINTER(ctypes.c_uint64),
    ctypes.c_int,
    ctypes.POINTER(VmRegionBasicInfo64),
    ctypes.POINTER(ctypes.c_uint32),
    ctypes.POINTER(ctypes.c_uint)
]
mach_vm_region.restype = ctypes.c_int

mach_vm_read = libc.mach_vm_read
mach_vm_read.argtypes = [
    ctypes.c_uint,
    ctypes.c_uint64,
    ctypes.c_uint64,
    ctypes.POINTER(ctypes.c_void_p),
    ctypes.POINTER(ctypes.c_uint32)
]
mach_vm_read.restype = ctypes.c_int

mach_vm_deallocate = libc.mach_vm_deallocate
mach_vm_deallocate.argtypes = [ctypes.c_uint, ctypes.c_uint64, ctypes.c_uint64]
mach_vm_deallocate.restype = ctypes.c_int


def aes_ecb_decrypt(key_bytes, cipher_bytes):
    """使用 macOS 原生 libcommonCrypto CCCrypt 解密单块 AES-128-ECB"""
    if len(key_bytes) != 16 or len(cipher_bytes) != 16:
        return None
    out_buf = (ctypes.c_uint8 * 32)()
    num_bytes = ctypes.c_size_t(0)
    status = libc.CCCrypt(
        1,  # kCCDecrypt
        0,  # kCCAlgorithmAES
        2,  # kCCOptionECBMode
        key_bytes, 16,
        None,
        cipher_bytes, 16,
        out_buf, 32,
        ctypes.byref(num_bytes)
    )
    if status == 0 and num_bytes.value >= 16:
        return bytes(out_buf[:num_bytes.value])
    return None


def find_wechat_pid():
    res = subprocess.run(["pgrep", "-x", "WeChat"], capture_output=True, text=True)
    if res.returncode == 0 and res.stdout.strip():
        return int(res.stdout.strip().split()[0])
    return None


def verify_hmac_page1(page, enc_key_bytes):
    if len(page) < PAGE_SZ or len(enc_key_bytes) != 32:
        return False
    salt = page[:SALT_SZ]
    mac_salt = bytes([b ^ 0x3a for b in salt])
    mac_key = hashlib.pbkdf2_hmac("sha512", enc_key_bytes, mac_salt, 2, 32)
    content = page[SALT_SZ:PAGE_SZ - RESERVE_SZ]
    iv = page[PAGE_SZ - RESERVE_SZ:PAGE_SZ - RESERVE_SZ + IV_SZ]
    stored = page[PAGE_SZ - RESERVE_SZ + IV_SZ:PAGE_SZ - RESERVE_SZ + IV_SZ + HMAC_SZ]
    data_to_mac = content + iv + (1).to_bytes(4, "little")
    computed = hmac.new(mac_key, data_to_mac, hashlib.sha512).digest()
    return hmac.compare_digest(computed, stored)


def find_sample_v2_info(target_path):
    """从附件目录中探测 V2 .dat 密文块与确定的 xor_key"""
    v2_magic = b"\x07\x08V2\x08\x07"
    search_dir = target_path
    if os.path.isfile(target_path):
        search_dir = os.path.dirname(target_path)

    account_dir = search_dir
    while account_dir and account_dir != "/" and not os.path.exists(os.path.join(account_dir, "msg")):
        parent = os.path.dirname(account_dir)
        if parent == account_dir:
            break
        account_dir = parent

    attach_dir = os.path.join(account_dir, "msg", "attach")
    if not os.path.exists(attach_dir):
        attach_dir = search_dir

    for root, _, files in os.walk(attach_dir):
        for f in files:
            if f.endswith("_t.dat") or (f.endswith(".dat") and not f.endswith("_h.dat")):
                full = os.path.join(root, f)
                try:
                    sz = os.path.getsize(full)
                    if 64 <= sz <= 2 * 1024 * 1024:
                        with open(full, "rb") as fp:
                            head = fp.read(31)
                            if head[:6] == v2_magic:
                                fp.seek(sz - 2)
                                tail = fp.read(2)
                                if len(tail) == 2 and (tail[0] ^ 0xFF == tail[1] ^ 0xD9):
                                    xor_key = tail[0] ^ 0xFF
                                    cipher16 = head[15:31]
                                    return cipher16, xor_key, full
                except Exception:
                    pass
    return None, None, None


def collect_dbs_from_json(json_path):
    dbs = []
    try:
        with open(json_path, "r", encoding="utf-8") as fp:
            data = json.load(fp)
        items = data.get("dbs", []) if isinstance(data, dict) else data
        for item in items:
            page = bytes.fromhex(item["page_hex"])
            salt = bytes.fromhex(item["salt_hex"]) if "salt_hex" in item else page[:SALT_SZ]
            dbs.append({
                "rel": item.get("rel", item.get("name", "unknown.db")),
                "name": item.get("name", "unknown.db"),
                "page": page,
                "salt": salt
            })
    except Exception as e:
        print(f"[-] 读取数据库描述文件失败: {e}")
    return dbs


def collect_dbs(db_storage_dir):
    dbs = []
    if not os.path.exists(db_storage_dir):
        return dbs
    for root, _, files in os.walk(db_storage_dir):
        for f in files:
            if f.endswith(".db") and not f.endswith("-wal") and not f.endswith("-shm"):
                full_path = os.path.join(root, f)
                rel_path = os.path.relpath(full_path, db_storage_dir)
                try:
                    with open(full_path, "rb") as fp:
                        page = fp.read(PAGE_SZ)
                    if len(page) == PAGE_SZ and not page.startswith(b"SQLite format 3"):
                        dbs.append({
                            "rel": rel_path,
                            "full": full_path,
                            "name": f,
                            "page": page,
                            "salt": page[:SALT_SZ]
                        })
                except Exception:
                    pass
    return dbs


def scan_memory_keys(task, db_list, v2_cipher=None):
    salts = [db["salt"] for db in db_list]
    raw_patterns = re.compile(rb"x'([0-9a-fA-F]{64})([0-9a-fA-F]{32})'")
    re_ascii_key = re.compile(rb"(?<![a-zA-Z0-9])[a-zA-Z0-9]{16,32}(?![a-zA-Z0-9])")

    candidates = set()
    salt_adjacent = set()
    found_image_key = None

    addr = ctypes.c_uint64(0)
    info_count_expected = ctypes.c_uint32(9)

    while True:
        size = ctypes.c_uint64(0)
        info = VmRegionBasicInfo64()
        info_count = ctypes.c_uint32(info_count_expected.value)
        obj_name = ctypes.c_uint(0)

        kr = mach_vm_region(
            task,
            ctypes.byref(addr),
            ctypes.byref(size),
            VM_REGION_BASIC_INFO_64,
            ctypes.byref(info),
            ctypes.byref(info_count),
            ctypes.byref(obj_name)
        )

        if kr != KERN_SUCCESS:
            break

        region_size = size.value
        current_addr = addr.value

        if region_size == 0:
            addr = ctypes.c_uint64(current_addr + 1)
            continue

        readable = (info.protection & VM_PROT_READ) != 0
        writable = (info.protection & VM_PROT_WRITE) != 0

        # 堆上内存：扫描读写区域或只读代码块
        if readable and (writable or region_size <= 64 * 1024 * 1024) and 0 < region_size < 512 * 1024 * 1024:
            end_addr = current_addr + region_size
            ca = current_addr

            while ca < end_addr:
                cs = min(end_addr - ca, CHUNK_SIZE)
                data_ptr = ctypes.c_void_p()
                dc = ctypes.c_uint32(0)

                kr_read = mach_vm_read(task, ca, cs, ctypes.byref(data_ptr), ctypes.byref(dc))
                if kr_read == KERN_SUCCESS and data_ptr.value:
                    buf = ctypes.string_at(data_ptr.value, dc.value)

                    # 1. 查找 x'<64hex><32hex>'
                    for m in raw_patterns.finditer(buf):
                        try:
                            k_hex = m.group(1).decode("ascii").lower()
                            candidates.add(k_hex)
                        except Exception:
                            pass

                    # 2. 查找 salt 邻接的 32 字节原始密钥
                    for s in salts:
                        start_pos = 0
                        while True:
                            idx = buf.find(s, start_pos)
                            if idx == -1:
                                break
                            if idx >= 32:
                                salt_adjacent.add(buf[idx - 32:idx].hex().lower())
                            if idx + len(s) + 32 <= len(buf):
                                salt_adjacent.add(buf[idx + len(s):idx + len(s) + 32].hex().lower())
                            start_pos = idx + 1

                    # 3. 扫描图片 AES 密钥（若提供了样本密文且尚未找到）
                    if v2_cipher and not found_image_key:
                        for m in re_ascii_key.finditer(buf):
                            cand_ascii = m.group()[:16]
                            dec = aes_ecb_decrypt(cand_ascii, v2_cipher)
                            if dec:
                                if dec[:3] == b"\xFF\xD8\xFF" or dec[:4] == b"\x89PNG":
                                    found_image_key = cand_ascii.decode("ascii")
                                    break

                    mach_vm_deallocate(mach_task_self(), data_ptr.value, dc.value)

                if cs > 128:
                    ca += cs - 128
                else:
                    ca += cs

        addr = ctypes.c_uint64(current_addr + region_size)

    all_cands = list(candidates) + list(salt_adjacent)
    return all_cands, found_image_key


def get_real_user_home():
    sudo_user = os.environ.get("SUDO_USER")
    if sudo_user:
        import pwd
        try:
            return pwd.getpwnam(sudo_user).pw_dir
        except Exception:
            pass
    return os.path.expanduser("~")


def main():
    print("=== 微信 4.x 本地数据库与附件密钥提取器 ===")

    if len(sys.argv) < 2:
        print("用法: sudo python3 extract_keys.py <db_storage_dir | db_info.json> [output_json]")
        home = get_real_user_home()
        xwechat = os.path.join(home, "Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files")
        if os.path.exists(xwechat):
            for acc in os.listdir(xwechat):
                cand = os.path.join(xwechat, acc, "db_storage")
                if os.path.exists(cand):
                    print(f"[*] 自动定位到账号目录: {cand}")
                    input_target = cand
                    break
        else:
            sys.exit(1)
    else:
        input_target = sys.argv[1]

    home = get_real_user_home()
    default_output = os.path.join(home, ".config/wx-cli/all_keys.json")
    output_json = sys.argv[2] if len(sys.argv) > 2 else default_output
    run_extraction(input_target, output_json)


def run_extraction(input_target, output_json):
    pid = find_wechat_pid()
    if not pid:
        print("[-] 未检测到运行中的微信进程。请先打开微信并登录！")
        sys.exit(2)

    print(f"[+] 微信正在运行 (PID: {pid})")

    # 尝试寻找样本 V2 图片密文与 xor_key
    sample_cipher, sample_xor, sample_path = find_sample_v2_info(input_target)
    if sample_cipher:
        print(f"[+] 发现 V2 图片样本: {os.path.basename(sample_path)} (XOR Key: 0x{sample_xor:02x})")

    if os.path.isfile(input_target) and input_target.endswith(".json"):
        print(f"[+] 从描述文件加载数据库信息: {input_target}")
        dbs = collect_dbs_from_json(input_target)
    else:
        dbs = collect_dbs(input_target)

    print(f"[+] 目标包含 {len(dbs)} 个待匹配数据库")

    task = ctypes.c_uint()
    kr = task_for_pid(mach_task_self(), pid, ctypes.byref(task))
    if kr != KERN_SUCCESS:
        print(f"[-] task_for_pid 失败 (错误码: {kr})。")
        print("[-] 微信启用了 Hardened Runtime 加固，本脚本需要管理员权限。")
        print("[-] 请使用 sudo 运行：sudo python3 extract_keys.py ...")
        sys.exit(4)

    print(f"[+] 成功获取微信进程 Task Port: {task.value}，开始扫描内存...")
    start_time = time.time()
    candidates, image_key = scan_memory_keys(task.value, dbs, sample_cipher)
    print(f"[+] 扫描完成（耗时 {time.time() - start_time:.2f}s），获得 {len(candidates)} 个候选密钥")

    matched_keys = {}
    matched_set = set()
    for db in dbs:
        for cand in candidates:
            if len(cand) == 64:
                try:
                    cand_bytes = bytes.fromhex(cand)
                    if verify_hmac_page1(db["page"], cand_bytes):
                        matched_keys[db["rel"]] = cand
                        matched_keys[db["name"]] = cand
                        matched_set.add(cand)
                        if "contact" in db["rel"]:
                            matched_keys["contact.db"] = cand
                            matched_keys["contact"] = cand
                        if "session" in db["rel"]:
                            matched_keys["session.db"] = cand
                            matched_keys["session"] = cand
                        print(f"  [✓] 数据库匹配成功: {db['rel']} -> {cand[:16]}...{cand[-8:]}")
                        break
                except Exception:
                    pass

    final_output = {}
    final_output.update(matched_keys)
    final_output["_candidates"] = list(set(candidates))

    if image_key:
        final_output["image_aes_key"] = image_key
        if sample_xor is not None:
            final_output["image_xor_key"] = sample_xor
        print(f"  [✓] V2 图片 AES 密钥匹配成功: {image_key} (XOR: 0x{sample_xor:02x})")

    print(f"[+] 共成功匹配 {len(matched_set)} 个核心数据库密钥！")

    os.makedirs(os.path.dirname(output_json), exist_ok=True)
    with open(output_json, "w", encoding="utf-8") as f:
        json.dump(final_output, f, indent=2)

    try:
        sudo_uid = os.environ.get("SUDO_UID")
        sudo_gid = os.environ.get("SUDO_GID")
        if sudo_uid and sudo_gid:
            os.chown(output_json, int(sudo_uid), int(sudo_gid))
    except Exception:
        pass

    print(f"[✓] 密钥已成功保存到: {output_json}")


if __name__ == "__main__":
    main()

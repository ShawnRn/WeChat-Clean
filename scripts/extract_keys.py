#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
微信 4.x 数据库密钥提取器（macOS 专用，纯原生 Python + Mach VM / LLDB）
参考 wx-cli-again 实现，无需第三方依赖，可由 App 提权或终端一键执行。
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


def scan_memory_keys(task, db_list):
    salts = [db["salt"] for db in db_list]
    raw_patterns = re.compile(rb"x'([0-9a-fA-F]{64})([0-9a-fA-F]{32})'")
    
    candidates = set()
    salt_adjacent = set()

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

        # 堆上内存：优先扫描读写区域或较小的只读块
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
                            # 前向 32 字节
                            if idx >= 32:
                                salt_adjacent.add(buf[idx - 32:idx].hex())
                            # 后向 32 字节
                            if idx + len(s) + 32 <= len(buf):
                                salt_adjacent.add(buf[idx + len(s):idx + len(s) + 32].hex())
                            start_pos = idx + 1

                    mach_vm_deallocate(mach_task_self(), data_ptr.value, dc.value)

                # 重叠 128 字节防跨边界
                if cs > 128:
                    ca += cs - 128
                else:
                    ca += cs

        addr = ctypes.c_uint64(current_addr + region_size)

    return list(candidates) + list(salt_adjacent)


def main():
    print("=== 微信 4.x 本地数据库密钥提取器 ===")
    
    if len(sys.argv) < 2:
        print("用法: sudo python3 extract_keys.py <db_storage_dir> [output_json]")
        # 尝试自动定位用户微信目录
        home = os.path.expanduser("~")
        xwechat_dir = os.path.join(home, "Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files")
        if os.path.exists(xwechat_dir):
            for item in os.listdir(xwechat_dir):
                if item.startswith("wxid_") or os.path.isdir(os.path.join(xwechat_dir, item, "db_storage")):
                    db_storage_dir = os.path.join(xwechat_dir, item, "db_storage")
                    output_json = os.path.join(home, ".config/wx-cli/all_keys.json")
                    print(f"[*] 自动发现微信数据目录: {db_storage_dir}")
                    run_extraction(db_storage_dir, output_json)
                    return
        sys.exit(1)

    db_storage_dir = sys.argv[1]
    output_json = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser("~/.config/wx-cli/all_keys.json")
    run_extraction(db_storage_dir, output_json)


def run_extraction(db_storage_dir, output_json):
    pid = find_wechat_pid()
    if not pid:
        print("[-] 未检测到运行中的微信进程。请先打开微信并登录！")
        sys.exit(2)

    print(f"[+] 微信正在运行 (PID: {pid})")
    dbs = collect_dbs(db_storage_dir)
    print(f"[+] 在目标目录中发现 {len(dbs)} 个加密数据库")
    if not dbs:
        print(f"[-] 目录下未发现加密的 .db 文件: {db_storage_dir}")
        sys.exit(3)

    task = ctypes.c_uint()
    kr = task_for_pid(mach_task_self(), pid, ctypes.byref(task))
    if kr != KERN_SUCCESS:
        print(f"[-] task_for_pid 失败 (错误码: {kr})。")
        print("[-] 微信启用了 Hardened Runtime 加固，本脚本需要管理员权限。")
        print("[-] 请使用 sudo 运行：sudo python3 extract_keys.py ...")
        sys.exit(4)

    print(f"[+] 成功获取微信进程 Task Port: {task.value}，开始扫描内存...")
    start_time = time.time()
    candidates = scan_memory_keys(task.value, dbs)
    print(f"[+] 扫描完成（耗时 {time.time() - start_time:.2f}s），获得 {len(candidates)} 个候选密钥")

    matched_keys = {}
    for db in dbs:
        for cand in candidates:
            if len(cand) == 64:
                try:
                    cand_bytes = bytes.fromhex(cand)
                    if verify_hmac_page1(db["page"], cand_bytes):
                        matched_keys[db["rel"]] = cand
                        matched_keys[db["name"]] = cand
                        # 兼容 contact/contact.db 或 contact.db 两种索引
                        if "contact" in db["rel"]:
                            matched_keys["contact.db"] = cand
                            matched_keys["contact"] = cand
                        if "session" in db["rel"]:
                            matched_keys["session.db"] = cand
                            matched_keys["session"] = cand
                        print(f"  [✓] 匹配成功: {db['rel']} -> {cand[:16]}...{cand[-8:]}")
                        break
                except Exception:
                    pass

    print(f"[+] 共成功匹配 {len(matched_keys) // 2} 个核心数据库密钥！")

    # 写入 JSON
    os.makedirs(os.path.dirname(output_json), exist_ok=True)
    with open(output_json, "w", encoding="utf-8") as f:
        json.dump(matched_keys, f, indent=2)

    print(f"[✓] 密钥已成功保存到: {output_json}")


if __name__ == "__main__":
    main()

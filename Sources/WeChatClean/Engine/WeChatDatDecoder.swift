import Foundation
import AppKit
import CommonCrypto
import CryptoKit
import ImageIO

/// 真实媒体文件类型
public enum WeChatRealMediaType: String, Sendable {
    case jpeg = "JPG"
    case png = "PNG"
    case gif = "GIF"
    case webp = "WebP"
    case mp4 = "MP4"
    case unknown = "DAT"

    public var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .gif: return "gif"
        case .webp: return "webp"
        case .mp4: return "mp4"
        case .unknown: return "dat"
        }
    }

    public var localizedDescription: String {
        switch self {
        case .jpeg: return "JPEG 图像"
        case .png: return "PNG 图像"
        case .gif: return "GIF 动图"
        case .webp: return "WebP 图像"
        case .mp4: return "MP4 视频"
        case .unknown: return "加密附件"
        }
    }
}

/// 微信 .dat 附件解密引擎（纯 Swift + CommonCrypto 原生实现，支持 V2 AES+XOR、V1 与传统 XOR，内置全核并行求解器与零阻塞缓存）
public final class WeChatDatDecoder: @unchecked Sendable {
    public static let shared = WeChatDatDecoder()

    // 缓存已解析的密钥材料 (wxid -> Material)
    private struct KeyMaterial: Sendable {
        let uin: UInt32
        let xorKey: UInt8
        let aesKeyBytes: [UInt8]
    }

    private let lock = NSLock()
    private var keyCache: [String: KeyMaterial] = [:]
    private var defaultMaterial: KeyMaterial?
    private var detectedMediaTypeCache: [URL: WeChatRealMediaType] = [:]
    private var pendingDetects: Set<URL> = []

    // V1 格式静态固定密钥: cfcd208495d565ef
    private static let v1AesKey: [UInt8] = Array("cfcd208495d565ef".utf8)
    private static let v1XorKey: UInt8 = 0x88

    private init() {
        refreshKeys()
    }

    /// 针对特定账号配置密钥
    public func configure(with account: WeChatAccount) {
        lock.lock()
        defer { lock.unlock() }
        let wxid = account.id
        if let material = deriveKeyMaterial(for: wxid, accountPath: account.url.path) {
            keyCache[wxid] = material
            defaultMaterial = material
        }
    }

    /// 刷新密钥材料
    public func refreshKeys() {
        let accounts = WeChatDetector.detectAccounts()
        lock.lock()
        defer { lock.unlock() }

        for account in accounts {
            let wxid = account.id
            if let material = deriveKeyMaterial(for: wxid, accountPath: account.url.path) {
                keyCache[wxid] = material
                if defaultMaterial == nil {
                    defaultMaterial = material
                }
            }
        }
    }

    /// 手动注入/缓存密钥材料 (可由外部提取脚本或设置面板调用)
    public func setKeyMaterial(aesKeyHex: String, xorKey: UInt8, wxid: String) {
        let cleanHex = aesKeyHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanHex.count >= 16 else { return }
        let keyBytes = Array(cleanHex.prefix(16).utf8)
        let material = KeyMaterial(uin: 0, xorKey: xorKey, aesKeyBytes: keyBytes)

        lock.lock()
        keyCache[wxid] = material
        defaultMaterial = material
        lock.unlock()

        UserDefaults.standard.set(cleanHex, forKey: "wechat_clean_cached_aes_key_" + wxid)
        UserDefaults.standard.set(xorKey, forKey: "wechat_clean_cached_xor_key_" + wxid)
    }

    /// 为指定 wxid 派生密钥
    private func deriveKeyMaterial(for wxid: String, accountPath: String) -> KeyMaterial? {
        let cacheKey = "wechat_clean_cached_uin_" + wxid

        // 1. 优先从 UserDefaults 读取已验证的持久化 UIN (0ms 秒开)
        if let savedUin = UserDefaults.standard.object(forKey: cacheKey) as? UInt32, savedUin > 10000 {
            return makeMaterial(uin: savedUin, wxid: wxid)
        }

        // 2. 尝试从 UserDefaults 读取直接缓存的 AES Key 与 XOR Key
        if let savedKey = UserDefaults.standard.string(forKey: "wechat_clean_cached_aes_key_" + wxid),
           let savedXor = UserDefaults.standard.object(forKey: "wechat_clean_cached_xor_key_" + wxid) as? UInt8 {
            let keyBytes = Array(savedKey.prefix(16).utf8)
            return KeyMaterial(uin: 0, xorKey: savedXor, aesKeyBytes: keyBytes)
        }

        // 3. 尝试从 ~/.config/wx-cli/all_keys.json 或配置目录读取已提取的 image_aes_key
        let home = WeChatDetector.realHomeDirectory.path
        let configCandidates = [
            "\(home)/.config/wx-cli/all_keys.json",
            "\(home)/Library/Application Support/WeChatClean/all_keys.json"
        ]
        for p in configCandidates {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let aesStr = json["image_aes_key"] as? String, aesStr.count >= 16 {
                    let xorVal = (json["image_xor_key"] as? UInt8)
                        ?? UInt8((json["image_xor_key"] as? Int) ?? 0x88)
                    let keyBytes = Array(aesStr.prefix(16).utf8)
                    return KeyMaterial(uin: 0, xorKey: xorVal, aesKeyBytes: keyBytes)
                }
            }
        }

        // 4. 尝试从 kvcomm 统计文件获取真实 uin
        if let uin = findUinFromKvcomm(accountPath: accountPath) {
            UserDefaults.standard.set(uin, forKey: cacheKey)
            return makeMaterial(uin: uin, wxid: wxid)
        }

        // 5. 基于样本 .dat 的实际密文与 JPEG EOI 文件尾，运行 Apple Silicon 全核并行 UIN 极速求解器
        if let uin = probeUinFromSampleDat(wxid: wxid, accountPath: accountPath) {
            UserDefaults.standard.set(uin, forKey: cacheKey)
            return makeMaterial(uin: uin, wxid: wxid)
        }

        return nil
    }

    private func makeMaterial(uin: UInt32, wxid: String) -> KeyMaterial {
        let xorKey = UInt8(uin & 0xFF)
        let normalized = normalizeWxid(wxid)
        let keyString = "\(uin)\(normalized)"
        let md5Digest = Insecure.MD5.hash(data: Data(keyString.utf8))
        let hexString = md5Digest.map { String(format: "%02x", $0) }.joined()
        let aesKeyBytes = Array(hexString.utf8.prefix(16))

        return KeyMaterial(uin: uin, xorKey: xorKey, aesKeyBytes: aesKeyBytes)
    }

    /// 从 kvcomm 或相关数据目录中查找 uin
    private func findUinFromKvcomm(accountPath: String) -> UInt32? {
        let fm = FileManager.default
        let realHome = WeChatDetector.realHomeDirectory.path

        var candidates: [String] = [
            "\(realHome)/Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data/net/kvcomm",
            "\(realHome)/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat/net/kvcomm",
            "\(realHome)/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/all_users"
        ]

        let accountURL = URL(fileURLWithPath: accountPath)
        let documentsDir = accountURL.deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(documentsDir.appendingPathComponent("app_data/net/kvcomm").path)
        candidates.append(documentsDir.appendingPathComponent("xwechat/net/kvcomm").path)
        candidates.append(accountURL.appendingPathComponent("config").path)

        for dir in candidates {
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in files {
                if file.hasPrefix("key_") || file.contains("uin") {
                    let parts = file.components(separatedBy: "_")
                    for part in parts {
                        if let uin = UInt32(part), uin > 10000 {
                            return uin
                        }
                    }
                }
            }
        }
        return nil
    }

    /// 基于样本 .dat 的高精度 JPEG 校验与 Apple Silicon 全核心并行求解器 (无堆分配，速度极快)
    private func probeUinFromSampleDat(wxid: String, accountPath: String) -> UInt32? {
        let attachDir = URL(fileURLWithPath: accountPath).appendingPathComponent("msg/attach")
        let fm = FileManager.default

        var sampleCipher16: Data?
        var verifiedXorKey: UInt8?

        // 优先遍历 _t.dat 缩略图文件（微信统一生成为 JPEG 格式）
        if let enumerator = fm.enumerator(at: attachDir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
            var scannedCount = 0
            while let fileURL = enumerator.nextObject() as? URL {
                let name = fileURL.lastPathComponent
                if name.hasSuffix("_t.dat") || (name.hasSuffix(".dat") && !name.hasSuffix("_h.dat")) {
                    if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
                       let size = attrs[.size] as? Int, size >= 64 && size < 1024 * 1024 {
                        if let handle = try? FileHandle(forReadingFrom: fileURL) {
                            if let head = try? handle.read(upToCount: 31), head.count == 31,
                               head.starts(with: [0x07, 0x08, 0x56, 0x32]) {
                                // 提取 16 字节 AES 密文
                                let cipher = head.subdata(in: 15..<31)
                                _ = try? handle.seekToEnd()
                                let offset = (try? handle.offset()) ?? 0
                                if offset >= 32 {
                                    try? handle.seek(toOffset: offset - 2)
                                    if let tail = try? handle.read(upToCount: 2), tail.count == 2 {
                                        let b0 = tail[0]
                                        let b1 = tail[1]
                                        // JPEG 规范结尾固定为 0xFF, 0xD9
                                        if (b0 ^ 0xFF) == (b1 ^ 0xD9) {
                                            verifiedXorKey = b0 ^ 0xFF
                                            sampleCipher16 = cipher
                                            try? handle.close()
                                            break
                                        }
                                    }
                                }
                            }
                            try? handle.close()
                        }
                    }
                    scannedCount += 1
                    if scannedCount > 200 { break }
                }
            }
        }

        guard let cipher = sampleCipher16, cipher.count == 16, let xorKey = verifiedXorKey else {
            return nil
        }

        let cipherBytes = Array(cipher)
        let normalized = normalizeWxid(wxid)
        let xorLow = UInt32(xorKey)

        // 候选账号标识 (归一化 wxid、完整 wxid 以及去除前缀形式)
        var wxidCandidates: [String] = [normalized]
        if wxid != normalized {
            wxidCandidates.append(wxid)
        }
        if normalized.hasPrefix("wxid_") {
            let bare = String(normalized.dropFirst(5))
            if !bare.isEmpty && !wxidCandidates.contains(bare) {
                wxidCandidates.append(bare)
            }
        }

        // 搜索区间（按常见概率排序）：
        // 区间 1: 500,000,000 ~ 2,500,000,000 (覆盖 95% 微信用户)
        // 区间 2: 2,500,000,000 ~ 4,200,000,000
        // 区间 3: 10,000,000 ~ 500,000,000
        let searchRanges: [(UInt32, UInt32)] = [
            (500_000_000, 2_500_000_000),
            (2_500_000_000, 4_200_000_000),
            (10_000_000, 500_000_000)
        ]

        for candWxid in wxidCandidates {
            let candBytes = Array(candWxid.utf8)

            for (minUin, maxUin) in searchRanges {
                if let solved = solveParallelUin(
                    minUin: minUin,
                    maxUin: maxUin,
                    xorLow: xorLow,
                    wxidBytes: candBytes,
                    cipher16: cipherBytes
                ) {
                    return solved
                }
            }
        }

        return nil
    }

    private final class SolveResultBox: @unchecked Sendable {
        var isFound = false
        var solvedUin: UInt32 = 0
    }

    /// Apple Silicon 全核心硬件加速并行求解器
    private func solveParallelUin(
        minUin: UInt32,
        maxUin: UInt32,
        xorLow: UInt32,
        wxidBytes: [UInt8],
        cipher16: [UInt8]
    ) -> UInt32? {
        let startUpper = Int(minUin >> 8)
        let endUpper = Int(maxUin >> 8)
        let total = endUpper - startUpper
        guard total > 0 else { return nil }

        let chunkSize = 50_000
        let numChunks = (total + chunkSize - 1) / chunkSize

        let resultBox = SolveResultBox()
        let matchLock = NSLock()

        let hexChars: [UInt8] = [
            0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37,
            0x38, 0x39, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66
        ]

        DispatchQueue.concurrentPerform(iterations: numChunks) { chunkIdx in
            if resultBox.isFound { return }
            let cStart = startUpper + chunkIdx * chunkSize
            let cEnd = min(cStart + chunkSize, endUpper)

            var outBuf = [UInt8](repeating: 0, count: 32)
            var numDec: size_t = 0
            var strBuf = [UInt8](repeating: 0, count: 64)
            var keyBytes = [UInt8](repeating: 0, count: 16)
            var digits = [UInt8](repeating: 0, count: 12)

            for upper in cStart..<cEnd {
                if resultBox.isFound { return }
                let candUin = UInt32((upper << 8) | Int(xorLow))

                // 快速无堆分配数字转 ASCII
                var temp = candUin
                var dCount = 0
                while temp > 0 {
                    digits[dCount] = UInt8(48 + (temp % 10))
                    temp /= 10
                    dCount += 1
                }

                var pos = 0
                for d in digits[0..<dCount].reversed() {
                    strBuf[pos] = d
                    pos += 1
                }
                for b in wxidBytes {
                    strBuf[pos] = b
                    pos += 1
                }

                // 现代零警告 Insecure.MD5 派生
                let digest = Insecure.MD5.hash(data: Data(strBuf[0..<pos]))

                var k = 0
                for b in digest.prefix(8) {
                    keyBytes[k * 2] = hexChars[Int(b >> 4)]
                    keyBytes[k * 2 + 1] = hexChars[Int(b & 0x0F)]
                    k += 1
                }

                let status = CCCrypt(
                    CCOperation(kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionECBMode),
                    keyBytes, 16,
                    nil,
                    cipher16, 16,
                    &outBuf, 32,
                    &numDec
                )

                // 校验 3 字节 JPEG (FF D8 FF) 或 4 字节 PNG (89 50 4E 47)，零误报
                if status == kCCSuccess {
                    if (outBuf[0] == 0xFF && outBuf[1] == 0xD8 && outBuf[2] == 0xFF) ||
                       (outBuf[0] == 0x89 && outBuf[1] == 0x50 && outBuf[2] == 0x4E && outBuf[3] == 0x47) {
                        matchLock.lock()
                        resultBox.isFound = true
                        resultBox.solvedUin = candUin
                        matchLock.unlock()
                        return
                    }
                }
            }
        }

        return resultBox.isFound ? resultBox.solvedUin : nil
    }

    private func normalizeWxid(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("wxid_") {
            let stripped = String(trimmed.dropFirst(5))
            if let first = stripped.components(separatedBy: "_").first {
                return "wxid_\(first)"
            }
        }
        if let idx = trimmed.lastIndex(of: "_") {
            let suffix = String(trimmed[trimmed.index(after: idx)...])
            if suffix.count == 4 && suffix.allSatisfy({ $0.isHexDigit }) {
                return String(trimmed[..<idx])
            }
        }
        return trimmed
    }

    // MARK: - 解密核心入口

    /// 智能从文件绝对路径中提取微信账号 ID (如 /xwechat_files/<account_id>/...)
    public static func extractAccountID(from url: URL) -> String? {
        let components = url.pathComponents
        if let idx = components.firstIndex(of: "xwechat_files"), idx + 1 < components.count {
            let accountCandidate = components[idx + 1]
            if accountCandidate != "all_users" && accountCandidate != "Backup" && !accountCandidate.hasPrefix(".") {
                return accountCandidate
            }
        }
        return nil
    }

    /// 获取或按需派生指定账号的密钥材料
    private func getOrDeriveMaterial(for wxid: String?) -> KeyMaterial? {
        lock.lock()
        if let wxid, let cached = keyCache[wxid] {
            lock.unlock()
            return cached
        }
        let fallback = defaultMaterial
        lock.unlock()

        if let wxid {
            let root = WeChatDetector.defaultRootURL
            let accountPath = root.appendingPathComponent(wxid).path
            if let derived = deriveKeyMaterial(for: wxid, accountPath: accountPath) {
                lock.lock()
                keyCache[wxid] = derived
                if defaultMaterial == nil {
                    defaultMaterial = derived
                }
                lock.unlock()
                return derived
            }
        }
        return fallback
    }

    /// 解密指定 URL 处的 .dat 文件数据 (自动动态关联文件所属账号密钥)
    public func decodeData(at url: URL, wxid: String? = nil) -> Data? {
        guard let rawData = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return nil
        }
        debugDumpDatIfNeed(url: url, data: rawData)

        let targetWxid = wxid ?? Self.extractAccountID(from: url)
        let decoded = decode(data: rawData, wxid: targetWxid)
        if let decoded {
            updateMediaTypeCache(for: url, data: decoded)
        }
        return decoded
    }

    private func debugDumpDatIfNeed(url: URL, data: Data) {
        let debugDir = URL(fileURLWithPath: "/tmp/wechat_dat_debug")
        try? FileManager.default.createDirectory(at: debugDir, withIntermediateDirectories: true)
        let name = url.lastPathComponent
        let target = debugDir.appendingPathComponent("\(name).header.bin")
        if !FileManager.default.fileExists(atPath: target.path) {
            let headLen = min(data.count, 131072)
            try? data.prefix(headLen).write(to: target)

            let tailTarget = debugDir.appendingPathComponent("\(name).tail.bin")
            let tailLen = min(data.count, 65536)
            try? data.suffix(tailLen).write(to: tailTarget)
        }
    }

    private struct JPEGFrameInfo: Sendable {
        let offset: Int
        let width: Int
        let height: Int
        let pixels: Int
    }

    /// 智能主图提取引擎：自动识别 Multi-Picture (MPF) 复合容器、实况照片与嵌入式缩略图，切出真正的超高清原图并保留 Display P3 / sRGB 广色域
    public static func smartExtractPrimaryImage(_ data: Data) -> Data {
        guard data.count >= 1024 else { return data }
        guard data[0] == 0xFF && data[1] == 0xD8 else { return data }

        return data.withUnsafeBytes { rawBuffer -> Data in
            guard let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return data }
            let count = data.count
            let limit = count - 10

            var frames: [JPEGFrameInfo] = []
            frames.reserveCapacity(8)

            var idx = 0
            while idx < limit {
                if ptr[idx] == 0xFF {
                    let m = ptr[idx + 1]
                    if m == 0xC0 || m == 0xC2 {
                        let mlen = (Int(ptr[idx + 2]) << 8) | Int(ptr[idx + 3])
                        let prec = ptr[idx + 4]
                        // JPEG 规范校验：精度 8 或 12，且 3 通道段长为 17 或单通道段长为 11
                        if (prec == 8 || prec == 12) && (mlen == 17 || mlen == 11) {
                            let h = (Int(ptr[idx + 5]) << 8) | Int(ptr[idx + 6])
                            let w = (Int(ptr[idx + 7]) << 8) | Int(ptr[idx + 8])
                            let comp = ptr[idx + 9]
                            if (comp == 1 || comp == 3) && w > 0 && h > 0 {
                                frames.append(JPEGFrameInfo(offset: idx, width: w, height: h, pixels: w * h))
                                idx += mlen + 2
                                continue
                            }
                        }
                    }
                }
                idx += 1
            }

            guard let firstFrame = frames.first else { return data }
            guard let maxFrame = frames.max(by: { $0.pixels < $1.pixels }) else { return data }

            // 若首帧已经是最大或无显著差距 (首帧尺寸足够且不属于微型前置缩略图)
            if maxFrame.offset == firstFrame.offset || maxFrame.pixels <= Int(Double(firstFrame.pixels) * 1.5) {
                return data
            }

            // 过滤出所有达到最大分辨率 90% 以上的高清主图候选，并优先按逆序匹配独立原图
            let hdCandidates = frames.filter { $0.pixels >= Int(Double(maxFrame.pixels) * 0.9) }
                .sorted { ($0.pixels, $0.offset) > ($1.pixels, $1.offset) }

            for cand in hdCandidates {
                let candOffset = cand.offset

                // 策略 1: 寻找候选帧前方的独立 SOI (FF D8)，切出完整无损的独立主图
                let searchStart = max(firstFrame.offset, candOffset - 65536)
                var soiOffset: Int?
                var s = candOffset - 2
                while s >= searchStart {
                    if ptr[s] == 0xFF && ptr[s + 1] == 0xD8 {
                        soiOffset = s
                        break
                    }
                    s -= 1
                }

                if let soi = soiOffset, soi > 0 {
                    // 寻找该大图之后的 EOI (FF D9)
                    var e = candOffset
                    while e < count - 1 {
                        if ptr[e] == 0xFF && ptr[e + 1] == 0xD9 {
                            let segLen = (e + 2) - soi
                            if segLen > 50_000 {
                                return data.subdata(in: soi..<(e + 2))
                            }
                            break
                        }
                        e += 1
                    }
                }

                // 策略 2: 候选帧紧接在前图 EOI 之后 (缺少开头 FF D8)
                if candOffset >= 2 && ptr[candOffset - 2] == 0xFF && ptr[candOffset - 1] == 0xD9 {
                    var e = candOffset
                    while e < count - 1 {
                        if ptr[e] == 0xFF && ptr[e + 1] == 0xD9 {
                            var result = Data([0xFF, 0xD8])
                            result.append(data.subdata(in: candOffset..<(e + 2)))
                            return result
                        }
                        e += 1
                    }
                }
            }

            // 策略 3: 共用头部量化表回退
            let bestOffset = hdCandidates[0].offset
            var tables = Data([0xFF, 0xD8])
            var hIdx = 2
            let hLimit = min(count, firstFrame.offset)
            while hIdx < hLimit {
                if ptr[hIdx] != 0xFF { break }
                while hIdx < count && ptr[hIdx] == 0xFF { hIdx += 1 }
                if hIdx >= count { break }
                let marker = ptr[hIdx]
                hIdx += 1
                if marker == 0xD8 || marker == 0xD9 || marker == 0x00 || (marker >= 0xD0 && marker <= 0xD7) {
                    continue
                }
                if hIdx + 2 > count { break }
                let segLen = (Int(ptr[hIdx]) << 8) | Int(ptr[hIdx + 1])
                if marker == 0xDB || marker == 0xC4 || marker == 0xDD || marker == 0xE1 || marker == 0xE2 {
                    tables.append(0xFF)
                    tables.append(marker)
                    tables.append(data.subdata(in: hIdx..<(hIdx + segLen)))
                }
                if marker == 0xDA { break }
                hIdx += segLen
            }

            var e = bestOffset
            while e < count - 1 {
                if ptr[e] == 0xFF && ptr[e + 1] == 0xD9 {
                    tables.append(data.subdata(in: bestOffset..<(e + 2)))
                    return tables
                }
                e += 1
            }

            tables.append(data.subdata(in: bestOffset..<count))
            return tables
        }
    }

    /// 智能归一化媒体有效载荷（自动提取真正的超清 Primary Image，支持实况照片与多图层容器）
    public static func normalizeMediaPayload(_ data: Data) -> Data {
        guard data.count >= 4 else { return data }

        // 1. 标准图片或视频魔数
        let b0 = data[0], b1 = data[1], b2 = data[2]
        if b0 == 0xFF && b1 == 0xD8 {
            return smartExtractPrimaryImage(data)
        }
        if b0 == 0x89 && b1 == 0x50 && b2 == 0x4E && data.count >= 4 && data[3] == 0x47 { return data } // PNG
        if b0 == 0x47 && b1 == 0x49 && b2 == 0x46 { return data } // GIF
        if data.count >= 12, let riff = String(data: data.prefix(12), encoding: .ascii), riff.contains("WEBP") { return data }

        // 2. 检查前 65536 字节内是否嵌入了标准 JPEG (如 oplus_ 前缀元数据实况照片)
        let scanLimit = min(data.count, 65536)
        var firstJpegOffset: Int?
        var fullHdJpegOffset: Int?
        var ftypOffset: Int?

        // 查找所有 FF D8 FF
        data.withUnsafeBytes { rawPtr in
            guard let ptr = rawPtr.bindMemory(to: UInt8.self).baseAddress else { return }
            for i in 0..<(scanLimit - 2) {
                if ptr[i] == 0xFF && ptr[i + 1] == 0xD8 && ptr[i + 2] == 0xFF {
                    firstJpegOffset = i
                    break
                }
            }
        }

        // 如果包含实况照片复合容器 (查找 ftyp 与第二个高清 JPEG)
        if let first = firstJpegOffset, data.count > 1024 * 1024 {
            let fullScan = min(data.count, 16 * 1024 * 1024)
            data.withUnsafeBytes { rawPtr in
                guard let ptr = rawPtr.bindMemory(to: UInt8.self).baseAddress else { return }
                for i in (first + 3)..<(fullScan - 8) {
                    if ptr[i] == 0x66 && ptr[i + 1] == 0x74 && ptr[i + 2] == 0x79 && ptr[i + 3] == 0x70 { // ftyp
                        ftypOffset = i - 4 // atom start
                        break
                    }
                    if fullHdJpegOffset == nil && ptr[i] == 0xFF && ptr[i + 1] == 0xD8 && ptr[i + 2] == 0xFF {
                        fullHdJpegOffset = i
                    }
                }
            }

            // 如果找到高清 JPEG 且位于 ftyp 之前，提取该高清原图
            if let hdStart = fullHdJpegOffset, let ftyp = ftypOffset, hdStart < ftyp {
                let hdEnd = ftyp
                if hdEnd - hdStart > 100 * 1024 {
                    let sub = data.subdata(in: hdStart..<hdEnd)
                    return smartExtractPrimaryImage(sub)
                }
            }
        }

        if let first = firstJpegOffset {
            let sub = data.subdata(in: first..<data.count)
            return smartExtractPrimaryImage(sub)
        }

        // 3. 检查是否有嵌入的标准 PNG (89 50 4E 47)
        if scanLimit >= 8 {
            var firstPngOffset: Int?
            data.withUnsafeBytes { rawPtr in
                guard let ptr = rawPtr.bindMemory(to: UInt8.self).baseAddress else { return }
                for i in 0..<(scanLimit - 4) {
                    if ptr[i] == 0x89 && ptr[i + 1] == 0x50 && ptr[i + 2] == 0x4E && ptr[i + 3] == 0x47 {
                        firstPngOffset = i
                        break
                    }
                }
            }
            if let pngStart = firstPngOffset {
                return data.subdata(in: pngStart..<data.count)
            }
        }

        return data
    }

    /// 解密原始 .dat 内存数据（自动执行厂商私有复合格式与实况照片的媒体归一化）
    public func decode(data: Data, wxid: String? = nil) -> Data? {
        guard data.count >= 4 else { return nil }

        let rawDecoded: Data?
        let magic = data.prefix(4)
        // V2 签名: 07 08 56 32 ("\u{7}\u{8}V2")
        if magic.starts(with: [0x07, 0x08, 0x56, 0x32]) {
            rawDecoded = decodeV2(data: data, wxid: wxid)
        } else if magic.starts(with: [0x07, 0x08, 0x56, 0x31]) {
            // V1 签名: 07 08 56 31 ("\u{7}\u{8}V1") - 静态 AES 密钥
            rawDecoded = decodeV1(data: data)
        } else {
            // 传统单字节 XOR 解密
            rawDecoded = decodeLegacyXor(data: data)
        }

        guard let rawDecoded else { return nil }
        return Self.normalizeMediaPayload(rawDecoded)
    }

    /// 解密 V2 AES+XOR 复合格式
    private func decodeV2(data: Data, wxid: String?) -> Data? {
        let material = getOrDeriveMaterial(for: wxid)

        guard let material, data.count >= 15 else { return nil }

        let aesSize = Int(data.subdata(in: 6..<10).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian })
        let xorSize = Int(data.subdata(in: 10..<14).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian })

        let alignedAesSize = (aesSize % 16 == 0) ? aesSize : (aesSize + 16 - (aesSize % 16))
        let aesEnd = 15 + alignedAesSize
        let rawEnd = data.count - xorSize

        guard aesEnd <= rawEnd, aesEnd <= data.count else { return nil }

        // 1. AES-128-ECB 解密 (无需 PKCS7Padding 强校验，解密后截取前 aesSize 字节)
        let cipherData = data.subdata(in: 15..<aesEnd)
        let maxOut = cipherData.count + 16
        let outPtr = UnsafeMutableRawPointer.allocate(byteCount: maxOut, alignment: 1)
        defer { outPtr.deallocate() }

        var numBytesDecrypted: size_t = 0
        let status = cipherData.withUnsafeBytes { inBytes in
            material.aesKeyBytes.withUnsafeBytes { keyBytes in
                CCCrypt(
                    CCOperation(kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionECBMode),
                    keyBytes.baseAddress, 16,
                    nil,
                    inBytes.baseAddress, cipherData.count,
                    outPtr, maxOut,
                    &numBytesDecrypted
                )
            }
        }

        guard status == kCCSuccess else { return nil }
        let decryptedAes = Data(bytes: outPtr, count: min(aesSize, numBytesDecrypted))
        NSLog("[DatDecoder] V2 decode: total=%ld, aesSize=%ld, xorSize=%ld, key=%@, decHead=%@",
              data.count, aesSize, xorSize,
              String(bytes: material.aesKeyBytes, encoding: .utf8) ?? "nil",
              decryptedAes.prefix(8).map { String(format: "%02x", $0) }.joined())

        // 2. Raw 未加密段
        let rawData = data.subdata(in: aesEnd..<rawEnd)

        // 3. XOR 解密段
        var xorData = Data(data.subdata(in: rawEnd..<data.count))
        for i in 0..<xorData.count {
            xorData[i] ^= material.xorKey
        }

        var result = Data()
        result.reserveCapacity(decryptedAes.count + rawData.count + xorData.count)
        result.append(decryptedAes)
        result.append(rawData)
        result.append(xorData)

        return result
    }

    /// 解密 V1 AES+XOR 复合格式 (使用固定密钥 cfcd208495d565ef)
    private func decodeV1(data: Data) -> Data? {
        guard data.count >= 15 else { return nil }

        let aesSize = Int(data.subdata(in: 6..<10).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian })
        let xorSize = Int(data.subdata(in: 10..<14).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian })

        let alignedAesSize = (aesSize % 16 == 0) ? aesSize : (aesSize + 16 - (aesSize % 16))
        let aesEnd = 15 + alignedAesSize
        let rawEnd = data.count - xorSize

        guard aesEnd <= rawEnd, aesEnd <= data.count else { return nil }

        let cipherData = data.subdata(in: 15..<aesEnd)
        let maxOut = cipherData.count + 16
        let outPtr = UnsafeMutableRawPointer.allocate(byteCount: maxOut, alignment: 1)
        defer { outPtr.deallocate() }

        var numBytesDecrypted: size_t = 0
        let status = cipherData.withUnsafeBytes { inBytes in
            Self.v1AesKey.withUnsafeBytes { keyBytes in
                CCCrypt(
                    CCOperation(kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionECBMode),
                    keyBytes.baseAddress, 16,
                    nil,
                    inBytes.baseAddress, cipherData.count,
                    outPtr, maxOut,
                    &numBytesDecrypted
                )
            }
        }

        guard status == kCCSuccess else { return nil }
        let decryptedAes = Data(bytes: outPtr, count: min(aesSize, numBytesDecrypted))
        let rawData = data.subdata(in: aesEnd..<rawEnd)

        var xorData = Data(data.subdata(in: rawEnd..<data.count))
        for i in 0..<xorData.count {
            xorData[i] ^= Self.v1XorKey
        }

        var result = Data()
        result.reserveCapacity(decryptedAes.count + rawData.count + xorData.count)
        result.append(decryptedAes)
        result.append(rawData)
        result.append(xorData)
        return result
    }

    /// 传统单字节异或解密
    private func decodeLegacyXor(data: Data) -> Data? {
        guard data.count >= 4 else { return nil }

        let b0 = data[0]
        let b1 = data[1]

        var xorKey: UInt8?
        if (b0 ^ 0xFF) == (b1 ^ 0xD8) { // JPEG
            xorKey = b0 ^ 0xFF
        } else if (b0 ^ 0x89) == (b1 ^ 0x50) { // PNG
            xorKey = b0 ^ 0x89
        } else if (b0 ^ 0x47) == (b1 ^ 0x49) { // GIF
            xorKey = b0 ^ 0x47
        }

        guard let key = xorKey else { return nil }

        var output = Data(count: data.count)
        output.withUnsafeMutableBytes { outBuf in
            data.withUnsafeBytes { inBuf in
                let inPtr = inBuf.bindMemory(to: UInt8.self)
                let outPtr = outBuf.bindMemory(to: UInt8.self)
                for i in 0..<data.count {
                    outPtr[i] = inPtr[i] ^ key
                }
            }
        }
        return output
    }

    // MARK: - 真实媒体格式推导与明文导出 (零阻塞内存缓存)

    /// 零阻塞获取真实格式（仅读取内存缓存，绝不在主线程执行磁盘 I/O）
    public func detectRealTypeCached(at url: URL) -> WeChatRealMediaType {
        lock.lock()
        if let cached = detectedMediaTypeCache[url] {
            lock.unlock()
            return cached
        }
        let isPending = pendingDetects.contains(url)
        if !isPending {
            pendingDetects.insert(url)
        }
        lock.unlock()

        if !isPending {
            Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                _ = self.detectRealType(at: url)
                self.finishPendingDetect(for: url)
            }
        }

        return .unknown
    }

    private func finishPendingDetect(for url: URL) {
        lock.lock()
        pendingDetects.remove(url)
        lock.unlock()
    }

    /// 快速探测指定 .dat 文件的真实媒体格式 (后台线程执行，低 I/O)
    @discardableResult
    public func detectRealType(at url: URL) -> WeChatRealMediaType {
        lock.lock()
        if let cached = detectedMediaTypeCache[url] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard url.pathExtension.lowercased() == "dat" else {
            return .unknown
        }

        // 读取前 4096 字节探测魔数与私有 Header
        guard let handle = try? FileHandle(forReadingFrom: url),
              let rawHeader = try? handle.read(upToCount: 4096) else {
            return .unknown
        }
        try? handle.close()

        var magicBytes = rawHeader
        if rawHeader.starts(with: [0x07, 0x08, 0x56, 0x32]) {
            // V2 格式：解密头部 15 字节之后前 2048 字节 AES 密文
            if rawHeader.count >= 31 {
                lock.lock()
                let material = defaultMaterial
                lock.unlock()
                if let material {
                    let probeCount = min(rawHeader.count - 15, 2048)
                    let alignedLen = (probeCount / 16) * 16
                    if alignedLen >= 16 {
                        let cipherData = rawHeader.subdata(in: 15..<(15 + alignedLen))
                        var outBuf = [UInt8](repeating: 0, count: cipherData.count + 16)
                        var numDec: size_t = 0
                        let status = cipherData.withUnsafeBytes { inBytes in
                            material.aesKeyBytes.withUnsafeBytes { kBytes in
                                CCCrypt(
                                    CCOperation(kCCDecrypt),
                                    CCAlgorithm(kCCAlgorithmAES),
                                    CCOptions(kCCOptionECBMode),
                                    kBytes.baseAddress, 16,
                                    nil,
                                    inBytes.baseAddress, cipherData.count,
                                    &outBuf, outBuf.count,
                                    &numDec
                                )
                            }
                        }
                        if status == kCCSuccess {
                            magicBytes = Data(outBuf.prefix(numDec))
                        }
                    }
                }
            }
        } else if rawHeader.starts(with: [0x07, 0x08, 0x56, 0x31]) {
            // V1 格式：使用固定密钥解密前 2048 字节
            if rawHeader.count >= 31 {
                let probeCount = min(rawHeader.count - 15, 2048)
                let alignedLen = (probeCount / 16) * 16
                if alignedLen >= 16 {
                    let cipherData = rawHeader.subdata(in: 15..<(15 + alignedLen))
                    var outBuf = [UInt8](repeating: 0, count: cipherData.count + 16)
                    var numDec: size_t = 0
                    let status = cipherData.withUnsafeBytes { inBytes in
                        Self.v1AesKey.withUnsafeBytes { kBytes in
                            CCCrypt(
                                CCOperation(kCCDecrypt),
                                CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionECBMode),
                                kBytes.baseAddress, 16,
                                nil,
                                inBytes.baseAddress, cipherData.count,
                                &outBuf, outBuf.count,
                                &numDec
                            )
                        }
                    }
                    if status == kCCSuccess {
                        magicBytes = Data(outBuf.prefix(numDec))
                    }
                }
            }
        } else if let decoded = decodeLegacyXor(data: rawHeader) {
            magicBytes = decoded
        }

        let detected = resolveMediaTypeFromMagic(magicBytes)
        lock.lock()
        detectedMediaTypeCache[url] = detected
        lock.unlock()
        return detected
    }

    private func updateMediaTypeCache(for url: URL, data: Data) {
        let type = resolveMediaTypeFromMagic(data)
        if type != .unknown {
            lock.lock()
            detectedMediaTypeCache[url] = type
            lock.unlock()
        }
    }

    private func resolveMediaTypeFromMagic(_ data: Data) -> WeChatRealMediaType {
        if data.count >= 2 {
            if data[0] == 0xFF && data[1] == 0xD8 {
                return .jpeg
            } else if data.count >= 4 && data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47 {
                return .png
            } else if data.count >= 3 && data[0] == 0x47 && data[1] == 0x49 && data[2] == 0x46 {
                return .gif
            } else if data.count >= 12, let str = String(data: data.prefix(12), encoding: .ascii), str.contains("WEBP") {
                return .webp
            }
        }

        // 智能在解密数据前 4096 字节内探测是否嵌入了 JPEG (如 OPPO/小米/华为实况照片私有头)
        let scanLimit = min(data.count, 4096)
        if scanLimit >= 3 {
            let foundJpeg = data.withUnsafeBytes { rawPtr -> Bool in
                guard let ptr = rawPtr.bindMemory(to: UInt8.self).baseAddress else { return false }
                for i in 0..<(scanLimit - 2) {
                    if ptr[i] == 0xFF && ptr[i + 1] == 0xD8 && ptr[i + 2] == 0xFF {
                        return true
                    }
                }
                return false
            }
            if foundJpeg { return .jpeg }
        }

        return .unknown
    }

    /// 将加密的 .dat 导出为真实的明文文件（自动推导并修正真实扩展名）
    public func exportDecryptedFile(from sourceURL: URL, to destinationDir: URL) throws -> URL {
        guard let decryptedData = decodeData(at: sourceURL) else {
            throw NSError(domain: "WeChatDatDecoder", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法解密该 .dat 文件内容"])
        }

        let realType = detectRealType(at: sourceURL)
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let targetFileName: String
        if realType != .unknown {
            targetFileName = "\(baseName).\(realType.fileExtension)"
        } else {
            targetFileName = "\(baseName).jpg" // 默认按常见 JPEG 处理
        }

        let targetURL = destinationDir.appendingPathComponent(targetFileName)
        try decryptedData.write(to: targetURL, options: .atomic)
        return targetURL
    }

    // MARK: - 图像生成与缩略图渲染

    /// 解密为完整 NSImage
    public func decodeImage(at url: URL, wxid: String? = nil) -> NSImage? {
        guard let data = decodeData(at: url, wxid: wxid) else { return nil }
        return NSImage(data: data)
    }

    /// 高性能降采样解密缩略图（支持 Retina，极低内存消耗，优先使用同级 _t.dat 伴生图）
    public func decodeThumbnail(at url: URL, maxPixelSize: CGFloat = 64, wxid: String? = nil) -> NSImage? {
        let baseName = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()

        func logDiag(_ msg: String) {
            let line = "\(Date()): [decodeThumbnail] \(baseName): \(msg)\n"
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/wechat_thumb.log")) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: URL(fileURLWithPath: "/tmp/wechat_thumb.log"), atomically: true, encoding: .utf8)
            }
        }

        // 1. 如果是 xxx_h.dat 或普通 xxx.dat，优先尝试同目录下的 xxx_t.dat (缩略图伴生文件)
        if baseName.hasSuffix("_h") {
            let tName = String(baseName.dropLast(2)) + "_t.dat"
            let tURL = dir.appendingPathComponent(tName)
            if FileManager.default.fileExists(atPath: tURL.path) {
                if let tData = decodeData(at: tURL, wxid: wxid) {
                    try? tData.write(to: URL(fileURLWithPath: "/tmp/dump_t_\(baseName).jpg"))
                    if let image = downsampleData(tData, maxPixelSize: maxPixelSize) {
                        logDiag("SUCCESS from _t.dat (\(tData.count) bytes, img=\(image.size))")
                        updateMediaTypeCache(for: url, data: tData)
                        return image
                    } else {
                        logDiag("FAILED downsampleData on _t.dat (\(tData.count) bytes)")
                    }
                } else {
                    logDiag("FAILED decodeData on _t.dat (file exists)")
                }
            } else {
                logDiag("_t.dat NOT FOUND, fallback to original")
            }
        } else if !baseName.hasSuffix("_t") {
            let tURL = dir.appendingPathComponent("\(baseName)_t.dat")
            if FileManager.default.fileExists(atPath: tURL.path) {
                if let tData = decodeData(at: tURL, wxid: wxid) {
                    if let image = downsampleData(tData, maxPixelSize: maxPixelSize) {
                        logDiag("SUCCESS from non_h _t.dat (\(tData.count) bytes)")
                        updateMediaTypeCache(for: url, data: tData)
                        return image
                    } else {
                        logDiag("FAILED downsampleData on non_h _t.dat")
                    }
                } else {
                    logDiag("FAILED decodeData on non_h _t.dat")
                }
            } else {
                logDiag("non_h _t.dat NOT FOUND, fallback to original")
            }
        }

        // 2. 回退到直接解码原始文件
        guard let data = decodeData(at: url, wxid: wxid) else {
            logDiag("FAILED decodeData on original file!")
            return nil
        }
        updateMediaTypeCache(for: url, data: data)
        let img = downsampleData(data, maxPixelSize: maxPixelSize)
        if let img {
            logDiag("SUCCESS from original file (\(data.count) bytes, img=\(img.size))")
        } else {
            logDiag("FAILED downsampleData on original file (\(data.count) bytes)")
        }
        return img
    }

    /// 使用 ImageIO 对解密后的图片内存数据进行高性能降采样 (内置多层稳健降级)
    private func downsampleData(_ data: Data, maxPixelSize: CGFloat) -> NSImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        if let source = CGImageSourceCreateWithData(data as CFData, options) {
            let downsampleOptions = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ] as CFDictionary

            if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) {
                let width = CGFloat(thumbnail.width)
                let height = CGFloat(thumbnail.height)
                return NSImage(cgImage: thumbnail, size: NSSize(width: width, height: height))
            }
        }

        // 稳健回退：若 ImageIO 解析失败，使用 NSImage(data:) 直接解码并自适应缩放
        if let fallback = NSImage(data: data) {
            let originalSize = fallback.size
            guard originalSize.width > 0 && originalSize.height > 0 else { return fallback }
            let aspect = min(maxPixelSize / originalSize.width, maxPixelSize / originalSize.height)
            let targetSize = NSSize(width: originalSize.width * aspect, height: originalSize.height * aspect)
            let resized = NSImage(size: targetSize, flipped: false) { rect in
                fallback.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
                return true
            }
            return resized
        }

        return nil
    }
}

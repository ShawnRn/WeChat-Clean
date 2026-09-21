import Foundation
import AppKit
import CommonCrypto
import CryptoKit
import ImageIO

/// 微信 .dat 附件解密引擎（纯 Swift + CommonCrypto 原生实现，支持 V2 AES+XOR 与传统 XOR）
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

    private init() {
        // 尝试根据已探测到的微信目录初始化默认密钥
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

    /// 为指定 wxid 派生密钥
    private func deriveKeyMaterial(for wxid: String, accountPath: String) -> KeyMaterial? {
        // 1. 尝试从 kvcomm 统计文件名获取 uin
        if let uin = findUinFromKvcomm(accountPath: accountPath) {
            return makeMaterial(uin: uin, wxid: wxid)
        }

        // 2. Fallback: 从 wxid 4 位哈希后缀多核爆破 uin
        if let uin = bruteforceUin(wxid: wxid, accountPath: accountPath) {
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

    /// 从 kvcomm 目录中查找 uin
    private func findUinFromKvcomm(accountPath: String) -> UInt32? {
        let fm = FileManager.default
        let realHome = WeChatDetector.realHomeDirectory.path

        var candidates: [String] = [
            "\(realHome)/Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data/net/kvcomm",
            "\(realHome)/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat/net/kvcomm"
        ]

        // 如果传入了 accountPath，往上推导
        let accountURL = URL(fileURLWithPath: accountPath)
        let documentsDir = accountURL.deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(documentsDir.appendingPathComponent("app_data/net/kvcomm").path)
        candidates.append(documentsDir.appendingPathComponent("xwechat/net/kvcomm").path)

        for dir in candidates {
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in files {
                // 匹配形如 key_1129432576_... 或 key_reportnow_1129432576_...
                if file.hasPrefix("key_") {
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

    /// 根据 wxid 后缀爆破 uin（2^24 空间秒级匹配）
    private func bruteforceUin(wxid: String, accountPath: String) -> UInt32? {
        let parts = wxid.components(separatedBy: "_")
        guard let last = parts.last, last.count == 4,
              let targetSuffix = UInt16(last, radix: 16) else {
            return nil
        }

        // 探测一个样本 .dat 获取末尾 xor_key
        var sampleXorKey: UInt8 = 0x88 // 常见默认
        let attachDir = URL(fileURLWithPath: accountPath).appendingPathComponent("msg/attach")
        if let enumerator = FileManager.default.enumerator(at: attachDir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                if fileURL.pathExtension == "dat",
                   let handle = try? FileHandle(forReadingFrom: fileURL) {
                    if let data = try? handle.readToEnd(), data.count > 32,
                       data.starts(with: [0x07, 0x08, 0x56, 0x32]) {
                        if let lastByte = data.last {
                            sampleXorKey = lastByte ^ 0xD9
                            try? handle.close()
                            break
                        }
                    }
                    try? handle.close()
                }
            }
        }

        let xorLow = UInt32(sampleXorKey)
        let targetHi = UInt8((targetSuffix >> 8) & 0xFF)
        let targetLo = UInt8(targetSuffix & 0xFF)

        // 搜索 2^24 空间
        for upper in 0..<(1 << 24) {
            let uin = (UInt32(upper) << 8) | xorLow
            let uinStr = String(uin)
            let md5 = Insecure.MD5.hash(data: Data(uinStr.utf8))
            let firstTwo = Array(md5.prefix(2))
            if firstTwo[0] == targetHi && firstTwo[1] == targetLo {
                return uin
            }
        }
        return nil
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

    /// 解密指定 URL 处的 .dat 文件数据
    public func decodeData(at url: URL, wxid: String? = nil) -> Data? {
        guard let rawData = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return nil
        }
        return decode(data: rawData, wxid: wxid)
    }

    /// 解密原始 .dat 内存数据
    public func decode(data: Data, wxid: String? = nil) -> Data? {
        guard data.count >= 15 else { return nil }

        let magic = data.prefix(4)
        // V2 签名: 07 08 56 32 ("\u{7}\u{8}V2") 或 V1 签名: 07 08 56 31 ("\u{7}\u{8}V1")
        if magic.starts(with: [0x07, 0x08, 0x56]) {
            return decodeV2(data: data, wxid: wxid)
        }

        // 传统 XOR 解密
        return decodeLegacyXor(data: data)
    }

    /// 解密 V2 AES+XOR 复合格式
    private func decodeV2(data: Data, wxid: String?) -> Data? {
        lock.lock()
        let material = (wxid.flatMap { keyCache[$0] }) ?? defaultMaterial
        lock.unlock()

        guard let material else { return nil }

        let aesSize = Int(data.subdata(in: 6..<10).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian })
        let xorSize = Int(data.subdata(in: 10..<14).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian })

        let alignedAesSize = aesSize + (16 - (aesSize % 16))
        let aesEnd = 15 + alignedAesSize
        let rawEnd = data.count - xorSize

        guard aesEnd <= rawEnd, aesEnd <= data.count else { return nil }

        // 1. AES-128-ECB 解密
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
                    CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                    keyBytes.baseAddress, 16,
                    nil,
                    inBytes.baseAddress, cipherData.count,
                    outPtr, maxOut,
                    &numBytesDecrypted
                )
            }
        }

        guard status == kCCSuccess else { return nil }
        let decryptedAes = Data(bytes: outPtr, count: numBytesDecrypted)

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

    /// 传统单字节异或解密（自动侦测 JPEG 0xFFD8, PNG 0x8950, GIF 0x4749）
    private func decodeLegacyXor(data: Data) -> Data? {
        guard data.count >= 4 else { return nil }

        let b0 = data[0]
        let b1 = data[1]

        // 尝试反推 key
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

    // MARK: - 图像生成与缩略图渲染

    /// 解密为完整 NSImage
    public func decodeImage(at url: URL, wxid: String? = nil) -> NSImage? {
        guard let data = decodeData(at: url, wxid: wxid) else { return nil }
        return NSImage(data: data)
    }

    /// 高性能降采样解密缩略图（支持 Retina，极低内存消耗，优先使用同级 _t.dat 伴生图）
    public func decodeThumbnail(at url: URL, maxPixelSize: CGFloat = 64, wxid: String? = nil) -> NSImage? {
        // 1. 如果是 xxx_h.dat 或普通 xxx.dat，优先尝试同目录下的 xxx_t.dat（9KB 级，0.1ms 解密）
        let baseName = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()

        if baseName.hasSuffix("_h") {
            let tName = String(baseName.dropLast(2)) + "_t.dat"
            let tURL = dir.appendingPathComponent(tName)
            if FileManager.default.fileExists(atPath: tURL.path),
               let tData = decodeData(at: tURL, wxid: wxid),
               let image = downsampleData(tData, maxPixelSize: maxPixelSize) {
                return image
            }
        } else if !baseName.hasSuffix("_t") {
            let tURL = dir.appendingPathComponent("\(baseName)_t.dat")
            if FileManager.default.fileExists(atPath: tURL.path),
               let tData = decodeData(at: tURL, wxid: wxid),
               let image = downsampleData(tData, maxPixelSize: maxPixelSize) {
                return image
            }
        }

        // 2. 回退到直接解码原始文件
        guard let data = decodeData(at: url, wxid: wxid) else { return nil }
        return downsampleData(data, maxPixelSize: maxPixelSize)
    }

    /// 使用 ImageIO 对解密后的图片内存数据进行降采样
    private func downsampleData(_ data: Data, maxPixelSize: CGFloat) -> NSImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }

        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary

        if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) {
            return NSImage(cgImage: thumbnail, size: NSSize(width: maxPixelSize / 2.0, height: maxPixelSize / 2.0))
        }
        return NSImage(data: data)
    }
}


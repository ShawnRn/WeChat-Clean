import Foundation
import CommonCrypto

/// 纯 Swift 编写的轻量级 SQLCipher 4 数据库分页解密器（零外部依赖）
public enum SQLCipherDecryptor {
    public static let pageSize: Int = 4096
    public static let saltSize: Int = 16
    public static let reserveSize: Int = 80 // IV(16) + HMAC(64)
    public static let ivSize: Int = 16
    public static let hmacSize: Int = 64
    public static let sqliteHeader = Data("SQLite format 3\0".utf8)

    public enum DecryptError: LocalizedError {
        case invalidKeyLength(Int)
        case invalidFileSize
        case failedToOpenFile(String)
        case pageDecryptionFailed(status: CCCryptorStatus, page: Int)
        case invalidSqliteHeader

        public var errorDescription: String? {
            switch self {
            case .invalidKeyLength(let len):
                return "密钥长度无效 (需为 32 字节，当前为 \(len) 字节)"
            case .invalidFileSize:
                return "数据库文件大小无效或为空"
            case .failedToOpenFile(let path):
                return "无法打开文件: \(path)"
            case .pageDecryptionFailed(let status, let page):
                return "第 \(page) 页解密失败 (CCCrypt 错误码: \(status))"
            case .invalidSqliteHeader:
                return "解密后未发现合法的 SQLite 3 文件头，密钥可能错误"
            }
        }
    }

    /// 解密单个 SQLCipher 4 页面
    public static func decryptPage(key: Data, pageData: Data, pageNumber: Int) throws -> Data {
        guard pageData.count >= pageSize else {
            throw DecryptError.invalidFileSize
        }

        let ivOffset = pageSize - reserveSize
        let iv = pageData.subdata(in: ivOffset..<ivOffset + ivSize)

        var result = Data(count: pageSize)

        if pageNumber == 1 {
            // 第一页：跳过 16 字节 Salt，解密 [SALT_SZ ..< pageSize - reserveSize] (4000 字节)
            let cipherData = pageData.subdata(in: saltSize..<pageSize - reserveSize)
            let decrypted = try aesCbcDecrypt(key: key, iv: iv, ciphertext: cipherData, pageNumber: pageNumber)

            // 写入 SQLite 3 标准文件头 (16 字节)
            result.replaceSubrange(0..<16, with: sqliteHeader)
            // 写入解密后的页面数据 (4000 字节)
            result.replaceSubrange(16..<16 + decrypted.count, with: decrypted)
            // 末尾 80 字节已初始化为 0
        } else {
            // 后续页：解密 [0 ..< pageSize - reserveSize] (4016 字节)
            let cipherData = pageData.subdata(in: 0..<pageSize - reserveSize)
            let decrypted = try aesCbcDecrypt(key: key, iv: iv, ciphertext: cipherData, pageNumber: pageNumber)

            result.replaceSubrange(0..<decrypted.count, with: decrypted)
            // 末尾 80 字节已初始化为 0
        }

        return result
    }

    /// 使用 AES-256-CBC 模式解密数据块（无 PKCS#7 padding）
    private static func aesCbcDecrypt(key: Data, iv: Data, ciphertext: Data, pageNumber: Int) throws -> Data {
        guard key.count == 32 else {
            throw DecryptError.invalidKeyLength(key.count)
        }

        let outPtr = UnsafeMutableRawPointer.allocate(byteCount: ciphertext.count, alignment: 1)
        defer { outPtr.deallocate() }

        var numBytesDecrypted: size_t = 0

        let status = ciphertext.withUnsafeBytes { cipherBytes in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(0), // CBC 模式，无 padding
                        keyBytes.baseAddress, 32,
                        ivBytes.baseAddress,
                        cipherBytes.baseAddress, ciphertext.count,
                        outPtr, ciphertext.count,
                        &numBytesDecrypted
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw DecryptError.pageDecryptionFailed(status: status, page: pageNumber)
        }

        return Data(bytes: outPtr, count: numBytesDecrypted)
    }

    /// 校验 32 字节密钥是否能正确解密该数据库的第一页
    public static func validateKey(_ key: Data, forDatabase at: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: at) else { return false }
        defer { try? handle.close() }

        guard let firstPage = try? handle.read(upToCount: pageSize), firstPage.count == pageSize else {
            return false
        }

        guard let decrypted = try? decryptPage(key: key, pageData: firstPage, pageNumber: 1) else {
            return false
        }

        return decrypted.prefix(16) == sqliteHeader
    }

    /// 完整解密一个 SQLCipher 4 数据库文件，并流式输出到目标文件
    public static func decryptDatabase(at sourceURL: URL, to destinationURL: URL, key: Data) throws {
        guard key.count == 32 else {
            throw DecryptError.invalidKeyLength(key.count)
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: destinationURL.path) {
            try? fm.removeItem(at: destinationURL)
        }
        try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let sourceHandle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? sourceHandle.close() }

        let sourceSize = (try? sourceHandle.seekToEnd()) ?? 0
        try sourceHandle.seek(toOffset: 0)

        guard sourceSize >= UInt64(pageSize) else {
            throw DecryptError.invalidFileSize
        }

        fm.createFile(atPath: destinationURL.path, contents: nil)
        let destHandle = try FileHandle(forWritingTo: destinationURL)
        defer { try? destHandle.close() }

        var pageNumber = 1
        while let pageData = try sourceHandle.read(upToCount: pageSize), !pageData.isEmpty {
            var fullPage = pageData
            if fullPage.count < pageSize {
                fullPage.append(Data(count: pageSize - fullPage.count))
            }

            let decrypted = try decryptPage(key: key, pageData: fullPage, pageNumber: pageNumber)
            try destHandle.write(contentsOf: decrypted)
            pageNumber += 1
        }

        // 检查并合并 WAL 文件
        let walURL = URL(fileURLWithPath: sourceURL.path + "-wal")
        if fm.fileExists(atPath: walURL.path) {
            try? applyWAL(at: walURL, to: destinationURL, key: key)
        }
    }

    /// 应用 WAL 文件变更到已解密的数据库
    public static func applyWAL(at walURL: URL, to destURL: URL, key: Data) throws {
        guard let walData = try? Data(contentsOf: walURL), walData.count > 32 else { return }

        let s1 = walData.subdata(in: 16..<20).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let s2 = walData.subdata(in: 20..<24).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

        let frameHeaderSize = 24
        let frameSize = frameHeaderSize + pageSize
        let frameArea = walData.subdata(in: 32..<walData.count)

        guard let destHandle = try? FileHandle(forUpdating: destURL) else { return }
        defer { try? destHandle.close() }

        var pos = 0
        while pos + frameSize <= frameArea.count {
            let fh = frameArea.subdata(in: pos..<pos + frameHeaderSize)
            let pageData = frameArea.subdata(in: pos + frameHeaderSize..<pos + frameSize)

            let pgno = Int(fh.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            let fs1 = fh.subdata(in: 8..<12).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            let fs2 = fh.subdata(in: 12..<16).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

            pos += frameSize

            guard pgno > 0 && pgno <= 1_000_000, fs1 == s1 && fs2 == s2 else {
                continue
            }

            // WAL 帧没有 Salt 头，均走普通页解密逻辑
            if let decrypted = try? decryptPage(key: key, pageData: pageData, pageNumber: 2) {
                let fileOffset = UInt64((pgno - 1) * pageSize)
                try? destHandle.seek(toOffset: fileOffset)
                try? destHandle.write(contentsOf: decrypted)
            }
        }
    }
}

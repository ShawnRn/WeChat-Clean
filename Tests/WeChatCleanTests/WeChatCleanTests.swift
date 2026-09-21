import Testing
import Foundation
@testable import WeChatClean

@Suite("微信存储管理引擎测试")
struct WeChatCleanTests {

    @Test("微信 4.x 账号探测测试")
    func testAccountDetection() throws {
        // 1. 使用 Mock 目录测试探测逻辑与账号解析
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WeChatCleanDetectorTest_\(UUID().uuidString)")
        let mockAccountDir = tempDir.appendingPathComponent("wxid_mocktest9988_11aa")
        let mockMsgDir = mockAccountDir.appendingPathComponent("msg")
        try FileManager.default.createDirectory(at: mockMsgDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let result = WeChatDetector.detect(at: tempDir)
        switch result {
        case .success(let accounts):
            #expect(!accounts.isEmpty)
            if let first = accounts.first {
                #expect(first.id == "wxid_mocktest9988_11aa")
                #expect(first.displayName == "mocktest9988_11aa")
            }
        case .permissionDenied, .notFound:
            #expect(Bool(false), "Mock 目录应成功探测")
        }

        // 2. 检测本机真实微信账号（若有权限则验证真实数据）
        let realAccounts = WeChatDetector.detectAccounts()
        if !realAccounts.isEmpty {
            let first = realAccounts[0]
            #expect(first.id.contains("wxid_") || !first.displayName.isEmpty)
        }
    }

    @Test("硬链接去重逻辑测试")
    func testHardlinkDeduplication() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WeChatCleanTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 创建两个内容相同的文件
        let file1 = tempDir.appendingPathComponent("test1.mp4")
        let file2 = tempDir.appendingPathComponent("test2.mp4")
        let testData = Data(repeating: 0xAB, count: 200 * 1024) // 200KB
        try testData.write(to: file1)
        try testData.write(to: file2)

        var stat1 = stat()
        var stat2 = stat()
        stat(file1.path, &stat1)
        stat(file2.path, &stat2)

        let item1 = WeChatFileItem(
            url: file1,
            size: Int64(testData.count),
            category: .video,
            creationDate: Date(),
            modificationDate: Date(),
            inode: stat1.st_ino
        )
        let item2 = WeChatFileItem(
            url: file2,
            size: Int64(testData.count),
            category: .video,
            creationDate: Date(),
            modificationDate: Date(),
            inode: stat2.st_ino
        )

        let deduplicator = HardlinkDeduplicator()
        let duplicates = await deduplicator.findDuplicates(from: [item1, item2], minSize: 1024)

        #expect(duplicates.count == 1)
        #expect(duplicates[0].items.count == 2)
        #expect(duplicates[0].reclaimableSize == Int64(testData.count))

        // 执行硬链接去重
        let result = deduplicator.applyHardlinks(for: duplicates)
        #expect(result.linkedCount == 1)
        #expect(result.freedBytes == Int64(testData.count))

        // 验证去重后两个文件 inode 相同
        stat(file1.path, &stat1)
        stat(file2.path, &stat2)
        #expect(stat1.st_ino == stat2.st_ino)
        #expect(stat1.st_nlink == 2)
    }

    @Test("安全废纸篓回收与缩略图保护测试")
    func testSafeCleaner() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WeChatCleanTrashTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let videoFile = tempDir.appendingPathComponent("sample.mp4")
        let thumbFile = tempDir.appendingPathComponent("sample_thumb.jpg")
        try "video content".data(using: .utf8)?.write(to: videoFile)
        try "thumb content".data(using: .utf8)?.write(to: thumbFile)

        let videoItem = WeChatFileItem(
            url: videoFile,
            size: 13,
            category: .video,
            creationDate: Date(),
            modificationDate: Date(),
            thumbnailURL: thumbFile
        )

        let cleaner = CleanerEngine()
        let result = cleaner.clean(items: [videoItem], preserveThumbnails: true)

        #expect(result.deletedCount == 1)
        #expect(!FileManager.default.fileExists(atPath: videoFile.path))
        // 验证缩略图依然完整保留
        #expect(FileManager.default.fileExists(atPath: thumbFile.path))
    }

    @Test("微信 V2 .dat 图片解密测试")
    func testDatDecoder() throws {
        let accounts = WeChatDetector.detectAccounts()
        guard let account = accounts.first else {
            // 本地无权限或未登录微信，跳过真实附件解密
            return
        }

        WeChatDatDecoder.shared.configure(with: account)

        // 测试一个样本 .dat
        let sampleDat = URL(fileURLWithPath: account.url.path).appendingPathComponent("msg/attach/bf4184d8e51dcbec842b69b06ec13875/2025-04/Img/2247680d7a4b0d795a2126141c98c931_t.dat")
        if FileManager.default.fileExists(atPath: sampleDat.path) {
            let data = WeChatDatDecoder.shared.decodeData(at: sampleDat)
            #expect(data != nil)
            #expect(data?.starts(with: [0xFF, 0xD8, 0xFF]) == true)
            let thumb = WeChatDatDecoder.shared.decodeThumbnail(at: sampleDat, maxPixelSize: 64)
            #expect(thumb != nil)
        }

        // 测试截图中会话 62cc3bb1bf3531344e16f6a0ab85da8f 的 .dat 文件
        let sessionDat = URL(fileURLWithPath: account.url.path).appendingPathComponent("msg/attach/62cc3bb1bf3531344e16f6a0ab85da8f/2025-11/Img/77fe2fae24ae5d4cafd22e8f4ee8c309_h.dat")
        if FileManager.default.fileExists(atPath: sessionDat.path) {
            let data = WeChatDatDecoder.shared.decodeData(at: sessionDat)
            if let data {
                print("Header hex:", data.prefix(4).map { String(format: "%02x", $0) }.joined())
            }
            let thumb = WeChatDatDecoder.shared.decodeThumbnail(at: sessionDat, maxPixelSize: 56)
            #expect(thumb != nil)
        }
    }

    @Test("联系人管理器测试")
    func testContactManager() throws {
        let accounts = WeChatDetector.detectAccounts()
        guard let account = accounts.first else { return }

        WeChatContactManager.shared.loadContacts(for: account)
        let all = WeChatContactManager.shared.allContacts()
        print("Total contacts loaded:", all.count)
        for c in all.prefix(5) {
            print("Contact:", c.id, c.displayName, c.chatMD5)
        }
    }

    @Test("ThumbnailStore 完整流水线测试")
    func testThumbnailStorePipeline() async throws {
        let accounts = WeChatDetector.detectAccounts()
        guard let account = accounts.first else { return }

        WeChatDatDecoder.shared.configure(with: account)

        let datURL = URL(fileURLWithPath: account.url.path).appendingPathComponent("msg/attach/62cc3bb1bf3531344e16f6a0ab85da8f/2025-11/Img/77fe2fae24ae5d4cafd22e8f4ee8c309_h.dat")
        guard FileManager.default.fileExists(atPath: datURL.path) else { return }

        let item = WeChatFileItem(
            url: datURL,
            size: 32648012,
            category: .attach,
            creationDate: Date(),
            modificationDate: Date()
        )

        let _ = await ThumbnailStore.shared.thumbnail(for: item, size: 28)

        // 等待后台异步解码任务完成
        try await Task.sleep(nanoseconds: 1_500_000_000)

        let cached = await ThumbnailStore.shared.thumbnail(for: item, size: 28)
        #expect(cached != nil)
    }
}


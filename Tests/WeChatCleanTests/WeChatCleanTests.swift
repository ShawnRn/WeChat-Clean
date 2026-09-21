import Testing
import Foundation
import AppKit
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

        // 测试已验证的真实样本 .dat
        let sampleDat = URL(fileURLWithPath: account.url.path).appendingPathComponent("msg/attach/e788de13ef9767642d6474c3334ab239/2026-07/Img/1cbf94eb55c03d15eb0b7490839a26f4_h.dat")
        if FileManager.default.fileExists(atPath: sampleDat.path) {
            let data = WeChatDatDecoder.shared.decodeData(at: sampleDat)
            #expect(data != nil)
            #expect(data?.starts(with: [0xFF, 0xD8, 0xFF]) == true)
            let thumb = WeChatDatDecoder.shared.decodeThumbnail(at: sampleDat, maxPixelSize: 64)
            #expect(thumb != nil)
        }
    }

    @Test("诊断真实附件解密数据与色彩结构")
    func testDiagnoseRealDatFiles() throws {
        let accounts = WeChatDetector.detectAccounts()
        guard let account = accounts.first else {
            fputs("[-] 未检测到账号或无权限\n", stderr)
            return
        }

        WeChatDatDecoder.shared.configure(with: account)

        // 搜索截图中出现的文件
        let targetNames = [
            "722a84828e0f65043626e909e7317108_h.dat",
            "fb44177b09c45f071fe7be4c45bf0838_h.dat",
            "1cbf94eb55c03d15eb0b7490839a26f4_h.dat",
            "5a696b816196e32502e125c70bcf3351_h.dat",
            "819aba7b2d0d0dcb3fa4e52c7b401bbd_h.dat"
        ]

        let attachDir = URL(fileURLWithPath: account.url.path).appendingPathComponent("msg/attach")
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: attachDir, includingPropertiesForKeys: [.fileSizeKey]) else { return }

        var foundCount = 0
        while let fileURL = enumerator.nextObject() as? URL {
            let name = fileURL.lastPathComponent
            if targetNames.contains(name) {
                foundCount += 1
                fputs("\n[+] 发现目标诊断文件: \(name)\n", stderr)
                fputs("    路径: \(fileURL.path)\n", stderr)
                if let rawData = try? Data(contentsOf: fileURL) {
                    fputs("    文件大小: \(rawData.count) 字节\n", stderr)
                    fputs("    前 15 字节: \(rawData.prefix(15).map { String(format: "%02x", $0) }.joined())\n", stderr)
                    if rawData.count >= 15 {
                        let aesSize = Int(rawData.subdata(in: 6..<10).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian })
                        let xorSize = Int(rawData.subdata(in: 10..<14).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian })
                        let pad = rawData[14]
                        fputs("    aesSize=\(aesSize), xorSize=\(xorSize), pad=\(pad)\n", stderr)

                        // 尝试解密
                        if let decoded = WeChatDatDecoder.shared.decode(data: rawData) {
                            fputs("    解密成功: 大小 \(decoded.count) 字节, 开头 16: \(decoded.prefix(16).map { String(format: "%02x", $0) }.joined())\n", stderr)
                            let outURL = URL(fileURLWithPath: "/tmp/diag_\(name).bin")
                            try? decoded.write(to: outURL)
                            fputs("    已写入诊断文件: \(outURL.path)\n", stderr)
                        } else {
                            fputs("    [-] 解密失败!\n", stderr)
                        }
                    }
                }
                if foundCount >= 3 { break }
            }
        }
    }

    @Test("媒体归一化与账号提取测试")
    func testMediaNormalizationAndAccountExtraction() throws {
        // 1. 测试账号路径推导
        let testURL = URL(fileURLWithPath: "/Users/alice/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_test1234_5678/msg/attach/foo.dat")
        let accountID = WeChatDatDecoder.extractAccountID(from: testURL)
        #expect(accountID == "wxid_test1234_5678")

        // 2. 测试嵌入 JPEG 的实况照片/元数据归一化
        var mockLivePhoto = Data(repeating: 0x00, count: 1470) // 1470 字节厂商 Header
        mockLivePhoto.append(contentsOf: [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46]) // JFIF 头
        mockLivePhoto.append(Data(repeating: 0x20, count: 500))

        let normalized = WeChatDatDecoder.normalizeMediaPayload(mockLivePhoto)
        #expect(normalized.starts(with: [0xFF, 0xD8, 0xFF, 0xE0]))
        #expect(normalized.count == mockLivePhoto.count - 1470)
    }

    @Test("列表方向键键盘导航逻辑测试")
    @MainActor
    func testKeyboardNavigation() throws {
        let state = AppState()
        let item1 = WeChatFileItem(url: URL(fileURLWithPath: "/tmp/1.jpg"), size: 100, category: .video, creationDate: Date(), modificationDate: Date())
        let item2 = WeChatFileItem(url: URL(fileURLWithPath: "/tmp/2.jpg"), size: 200, category: .video, creationDate: Date(), modificationDate: Date())
        let item3 = WeChatFileItem(url: URL(fileURLWithPath: "/tmp/3.jpg"), size: 300, category: .video, creationDate: Date(), modificationDate: Date())

        state.displayedItems = [item1, item2, item3]

        // 初始未选 -> 下移默认选第 0 项
        state.selectNextItem()
        #expect(state.selectedItemIDs == [item1.id])

        // 下移 -> 选第 1 项
        state.selectNextItem()
        #expect(state.selectedItemIDs == [item2.id])

        // 下移 -> 选第 2 项 (末尾)
        state.selectNextItem()
        #expect(state.selectedItemIDs == [item3.id])

        // 再次下移 -> 保持末尾
        state.selectNextItem()
        #expect(state.selectedItemIDs == [item3.id])

        // 上移 -> 选第 1 项
        state.selectPreviousItem()
        #expect(state.selectedItemIDs == [item2.id])

        // 跳转首项
        state.selectFirstItem()
        #expect(state.selectedItemIDs == [item1.id])

        // 跳转末项
        state.selectLastItem()
        #expect(state.selectedItemIDs == [item3.id])
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
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 32,
            pixelsHigh: 32,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 32 * 4,
            bitsPerPixel: 32
        )!
        let sampleImageURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_thumb_\(UUID().uuidString).png")
        guard let pngData = rep.representation(using: .png, properties: [:]) else { return }
        try pngData.write(to: sampleImageURL)
        defer { try? FileManager.default.removeItem(at: sampleImageURL) }

        let item = WeChatFileItem(
            url: sampleImageURL,
            size: Int64(pngData.count),
            category: .attach,
            creationDate: Date(),
            modificationDate: Date()
        )

        let img = await ThumbnailStore.shared.loadThumbnail(for: item, size: 28)
        #expect(img != nil)

        let cached = await ThumbnailStore.shared.thumbnail(for: item, size: 28)
        #expect(cached != nil)
    }

    @Test("智能超清主图提取引擎测试")
    func testSmartPrimaryImageExtractor() throws {
        // 构建模拟多图层 JPEG:
        // 1. 前置 160x107 微型缩略图
        var mockCompound = Data([0xFF, 0xD8]) // SOI
        // 添加 DQT
        mockCompound.append(contentsOf: [0xFF, 0xDB, 0x00, 0x43, 0x00])
        mockCompound.append(Data(repeating: 0x10, count: 64))
        // 首图 SOF0 (160x107, 3 通道)
        mockCompound.append(contentsOf: [0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x6B, 0x00, 0xA0, 0x03])
        mockCompound.append(Data(repeating: 0x01, count: 9))
        // 首图 SOS
        mockCompound.append(contentsOf: [0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00])
        mockCompound.append(Data(repeating: 0xAA, count: 200))
        // 首图 EOI
        mockCompound.append(contentsOf: [0xFF, 0xD9])

        // 2. 紧跟后部的 6000x4000 超清主图 (共用/自带 SOF0)
        mockCompound.append(contentsOf: [0xFF, 0xC0, 0x00, 0x11, 0x08, 0x0F, 0xA0, 0x17, 0x70, 0x03]) // 6000x4000
        mockCompound.append(Data(repeating: 0x01, count: 9))
        mockCompound.append(contentsOf: [0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00])
        mockCompound.append(Data(repeating: 0xBB, count: 2000))
        mockCompound.append(contentsOf: [0xFF, 0xD9]) // EOI

        let extracted = WeChatDatDecoder.smartExtractPrimaryImage(mockCompound)
        #expect(extracted.count > 0)
        #expect(extracted.starts(with: [0xFF, 0xD8]))
        #expect(extracted.count < mockCompound.count || extracted.starts(with: [0xFF, 0xD8, 0xFF, 0xC0]))
    }
}


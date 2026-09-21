import Foundation
import System

public struct ScanResult: Sendable {
    public let items: [WeChatFileItem]
    public let itemMap: [String: WeChatFileItem]
    public let categorySizes: [WeChatCategory: Int64]
    public let sessions: [WeChatSessionItem]
    public let totalSize: Int64

    public init(
        items: [WeChatFileItem],
        itemMap: [String: WeChatFileItem],
        categorySizes: [WeChatCategory: Int64],
        sessions: [WeChatSessionItem] = [],
        totalSize: Int64
    ) {
        self.items = items
        self.itemMap = itemMap
        self.categorySizes = categorySizes
        self.sessions = sessions
        self.totalSize = totalSize
    }
}

public final class ScannerEngine: Sendable {
    public init() {}

    /// 扫描指定微信账号目录
    public func scan(
        account: WeChatAccount,
        onProgress: @Sendable @escaping (ScanProgress) -> Void
    ) async -> ScanResult {
        let rootURL = account.url
        var items: [WeChatFileItem] = []
        items.reserveCapacity(250_000)
        var itemMap: [String: WeChatFileItem] = [:]
        itemMap.reserveCapacity(250_000)

        var categorySizes: [WeChatCategory: Int64] = [:]
        for cat in WeChatCategory.allCases {
            categorySizes[cat] = 0
        }

        var totalBytes: Int64 = 0
        var count = 0
        var lastProgressTime = CFAbsoluteTimeGetCurrent()

        // 待扫描的关键子目录
        let targetDirs = [
            ("msg/video", WeChatCategory.video),
            ("msg/file", WeChatCategory.file),
            ("msg/attach", WeChatCategory.attach),
            ("cache", WeChatCategory.cache)
        ]

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey,
            .linkCountKey
        ]

        for (subPath, category) in targetDirs {
            let dirURL = rootURL.appendingPathComponent(subPath)
            guard FileManager.default.fileExists(atPath: dirURL.path) else { continue }

            let now = CFAbsoluteTimeGetCurrent()
            if now - lastProgressTime >= 0.25 {
                lastProgressTime = now
                onProgress(ScanProgress(
                    isScanning: true,
                    currentDirectory: subPath,
                    scannedCount: count,
                    totalBytes: totalBytes,
                    statusMessage: "正在扫描 \(category.rawValue)..."
                ))
            }

            // 第一遍：如果包含视频目录，预先索引缩略图
            var thumbMap: [String: URL] = [:]
            if category == .video {
                if let thumbEnumerator = FileManager.default.enumerator(
                    at: dirURL,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) {
                    while let fileURL = thumbEnumerator.nextObject() as? URL {
                        let name = fileURL.lastPathComponent
                        if name.hasSuffix("_thumb.jpg") {
                            let base = String(name.dropLast(10)) // 去掉 "_thumb.jpg"
                            thumbMap[base] = fileURL
                        }
                    }
                }
            }

            // 正式枚举文件
            guard let enumerator = FileManager.default.enumerator(
                at: dirURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            while let fileURL = enumerator.nextObject() as? URL {
                // 忽略系统临时文件
                let fileName = fileURL.lastPathComponent
                if fileName == ".DS_Store" { continue }

                // 视频目录下不把独立缩略图单独列出（已作为视频属性附带）
                if category == .video && fileName.hasSuffix("_thumb.jpg") {
                    continue
                }

                // 忽略零字节空文件
                guard let values = try? fileURL.resourceValues(forKeys: keys),
                      let isRegular = values.isRegularFile, isRegular,
                      let size = values.fileSize, size > 0 else {
                    continue
                }

                let fileSize = Int64(size)
                totalBytes += fileSize
                count += 1
                categorySizes[category, default: 0] += fileSize
                if fileSize >= 100 * 1024 * 1024 {
                    categorySizes[.largeFiles, default: 0] += fileSize
                }

                // 极速获取硬链接和 inode（仅在 linkCount > 1 时才进行 stat 系统调用，避免 20 万次无谓磁盘 I/O）
                var isHardlink = false
                var inode: UInt64 = 0
                if let linkCount = values.linkCount, linkCount > 1 {
                    isHardlink = true
                    var statBuf = stat()
                    if stat(fileURL.path, &statBuf) == 0 {
                        inode = statBuf.st_ino
                    }
                }

                // 匹配视频缩略图
                var thumbURL: URL? = nil
                if category == .video {
                    let baseName = fileURL.deletingPathExtension().lastPathComponent
                    thumbURL = thumbMap[baseName]
                }

                // 提取 sessionHash（若在 attach/{hash}/ 目录下）
                var sessionHash: String? = nil
                if category == .attach {
                    let components = fileURL.pathComponents
                    if let attachIdx = components.firstIndex(of: "attach"), attachIdx + 1 < components.count {
                        sessionHash = components[attachIdx + 1]
                    }
                }

                let rawModDate = values.contentModificationDate ?? Date()
                let createDate = values.creationDate ?? Date()
                // MS-DOS FAT 初始时间为 1980-01-01 (timestamp 315532800)
                // 解压自 docx/zip 的内部 xml 等文件常带有该默认时间，若 creationDate 合法 (>= 1980) 则回退使用真实创建时间
                let modDate: Date
                if rawModDate.timeIntervalSince1970 < 315532800 && createDate.timeIntervalSince1970 >= 315532800 {
                    modDate = createDate
                } else {
                    modDate = rawModDate
                }

                let item = WeChatFileItem(
                    url: fileURL,
                    size: fileSize,
                    category: category,
                    creationDate: createDate,
                    modificationDate: modDate,
                    thumbnailURL: thumbURL,
                    isHardlink: isHardlink,
                    inode: inode,
                    sessionHash: sessionHash
                )
                items.append(item)
                itemMap[item.id] = item

                // 严格限流刷新，每 250ms 最多通知一次，杜绝主线程 RunLoop 堆积卡死
                let currentTime = CFAbsoluteTimeGetCurrent()
                if currentTime - lastProgressTime >= 0.25 {
                    lastProgressTime = currentTime
                    onProgress(ScanProgress(
                        isScanning: true,
                        currentDirectory: subPath,
                        scannedCount: count,
                        totalBytes: totalBytes,
                        statusMessage: "已发现 \(count) 个项目 (\(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)))"
                    ))
                }
            }
        }

        categorySizes[.all] = totalBytes

        // 聚合会话/联系人附件信息
        let remarks = WeChatDetector.loadSessionRemarks(for: account.id)
        var sessionDict: [String: (size: Int64, count: Int, latestDate: Date, firstThumb: URL?)] = [:]
        for item in items where item.category == .attach {
            guard let hash = item.sessionHash else { continue }
            var entry = sessionDict[hash] ?? (size: 0, count: 0, latestDate: Date.distantPast, firstThumb: nil)
            entry.size += item.size
            entry.count += 1
            if item.modificationDate > entry.latestDate {
                entry.latestDate = item.modificationDate
            }
            if entry.firstThumb == nil {
                let ext = item.url.pathExtension.lowercased()
                if item.thumbnailURL != nil || ext == "jpg" || ext == "png" || ext == "dat" {
                    entry.firstThumb = item.thumbnailURL ?? item.url
                }
            }
            sessionDict[hash] = entry
        }

        let attachBaseURL = rootURL.appendingPathComponent("msg/attach")
        var sessions: [WeChatSessionItem] = []
        sessions.reserveCapacity(sessionDict.count)
        for (hash, data) in sessionDict {
            let sessionURL = attachBaseURL.appendingPathComponent(hash)
            let matchedContact = WeChatContactManager.shared.contact(forChatMD5: hash)
            sessions.append(WeChatSessionItem(
                id: hash,
                url: sessionURL,
                size: data.size,
                fileCount: data.count,
                latestDate: data.latestDate,
                customName: remarks[hash],
                firstThumbnailURL: data.firstThumb,
                contact: matchedContact
            ))
        }
        sessions.sort { $0.size > $1.size }

        onProgress(ScanProgress(
            isScanning: false,
            currentDirectory: "",
            scannedCount: count,
            totalBytes: totalBytes,
            statusMessage: "扫描完成，共 \(count) 个项目"
        ))

        return ScanResult(
            items: items,
            itemMap: itemMap,
            categorySizes: categorySizes,
            sessions: sessions,
            totalSize: totalBytes
        )
    }
}

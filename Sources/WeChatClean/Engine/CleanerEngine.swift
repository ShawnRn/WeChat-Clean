import Foundation

public struct CleanResult: Sendable {
    public let deletedCount: Int
    public let freedBytes: Int64
    public let failedItems: [WeChatFileItem]
}

public final class CleanerEngine: Sendable {
    public init() {}

    /// 路径安全校验（参考 Pearcleaner 严格防护机制，严禁触碰系统与关键用户目录）
    public static func isSafeToDelete(url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty else { return false }

        let blockedPaths: Set<String> = [
            "/",
            "/Applications",
            "/Library",
            "/System",
            "/usr",
            "/bin",
            "/sbin",
            "/etc",
            "/var",
            "/private",
            "/opt",
            NSHomeDirectory()
        ]

        if blockedPaths.contains(path) {
            return false
        }

        // 必须在 xwechat_files、微信数据目录或测试临时目录内
        return path.contains("xwechat_files") ||
               path.contains("Containers/com.tencent.xinWeChat") ||
               path.contains("WeChatCleanTrashTest")
    }

    /// 安全清理选中的文件（移至废纸篓并保护缩略图）
    public func clean(
        items: [WeChatFileItem],
        preserveThumbnails: Bool = true
    ) -> CleanResult {
        var deletedCount = 0
        var freedBytes: Int64 = 0
        var failedItems: [WeChatFileItem] = []

        for item in items {
            let fileURL = item.url

            // 安全守卫：非微信沙盒内文件或危险路径一律拒绝操作
            guard Self.isSafeToDelete(url: fileURL) else {
                failedItems.append(item)
                continue
            }

            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                continue
            }

            // 如果保留缩略图且是视频文件，同名 _thumb.jpg 坚决保留（Ghost Mode）
            // fileURL 是视频本体，删除视频本体后，_thumb.jpg 自然留存在原目录中

            // 使用系统废纸篓机制（支持放回原处，对齐 Pearcleaner）
            var success = false
            do {
                try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
                success = true
            } catch {
                success = false
            }

            if success {
                deletedCount += 1
                freedBytes += item.size
            } else {
                failedItems.append(item)
            }
        }

        return CleanResult(
            deletedCount: deletedCount,
            freedBytes: freedBytes,
            failedItems: failedItems
        )
    }

    /// 将指定目录或文件安全移入废纸篓（带路径守卫）
    @discardableResult
    public func trashItem(at url: URL) -> Bool {
        guard Self.isSafeToDelete(url: url) else { return false }
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return true
        } catch {
            return false
        }
    }
}

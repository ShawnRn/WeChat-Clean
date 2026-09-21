import Foundation
import CryptoKit

public struct DeduplicationResult: Sendable {
    public let linkedCount: Int
    public let freedBytes: Int64
    public let failedCount: Int
}

public final class HardlinkDeduplicator: Sendable {
    public init() {}

    /// 识别重复文件组
    public func findDuplicates(
        from items: [WeChatFileItem],
        minSize: Int64 = 1024 * 100 // 默认只对 >= 100KB 的文件进行去重比对
    ) async -> [DuplicateGroup] {
        // 1. 按文件大小初步分组
        var sizeGroups: [Int64: [WeChatFileItem]] = [:]
        for item in items where item.size >= minSize {
            sizeGroups[item.size, default: []].append(item)
        }

        // 仅保留文件数 >= 2 的大小组
        let candidateGroups = sizeGroups.values.filter { $0.count >= 2 }
        var duplicateGroups: [DuplicateGroup] = []

        for group in candidateGroups {
            // 2. 检查是否有不同 inode 的副本
            // 按快速指纹分组 (前 4KB + 后 4KB)
            var partialHashGroups: [String: [WeChatFileItem]] = [:]
            for item in group {
                if let partialHash = computePartialHash(for: item.url, size: item.size) {
                    partialHashGroups[partialHash, default: []].append(item)
                }
            }

            for partialItems in partialHashGroups.values where partialItems.count >= 2 {
                // 3. 计算完整 SHA256 进行最终确认
                var fullHashGroups: [String: [WeChatFileItem]] = [:]
                for item in partialItems {
                    if let fullHash = computeFullSHA256(for: item.url) {
                        fullHashGroups[fullHash, default: []].append(item)
                    }
                }

                for (hash, matchedItems) in fullHashGroups where matchedItems.count >= 2 {
                    duplicateGroups.append(DuplicateGroup(
                        id: hash,
                        fileSize: matchedItems[0].size,
                        items: matchedItems
                    ))
                }
            }
        }

        // 按可回收空间倒序排列
        return duplicateGroups.sorted { $0.reclaimableSize > $1.reclaimableSize }
    }

    /// 执行 APFS 硬链接替换，释放物理空间
    public func applyHardlinks(for groups: [DuplicateGroup]) -> DeduplicationResult {
        var linkedCount = 0
        var freedBytes: Int64 = 0
        var failedCount = 0

        for group in groups {
            guard group.items.count > 1 else { continue }
            let master = group.items[0]
            guard FileManager.default.fileExists(atPath: master.url.path) else { continue }

            var masterStat = stat()
            guard stat(master.url.path, &masterStat) == 0 else { continue }
            let masterInode = masterStat.st_ino

            for replica in group.items.dropFirst() {
                guard FileManager.default.fileExists(atPath: replica.url.path) else { continue }

                var replicaStat = stat()
                guard stat(replica.url.path, &replicaStat) == 0 else { continue }

                // 如果已经是同一个 inode，说明已经是硬链接
                if replicaStat.st_ino == masterInode {
                    continue
                }

                let targetPath = replica.url.path
                let tempLinkPath = targetPath + ".hlink_tmp"

                // 确保清理遗留临时文件
                unlink(tempLinkPath)

                // 1. 创建硬链接指向 master
                if link(master.url.path, tempLinkPath) == 0 {
                    // 2. 原子替换原有 replica
                    if rename(tempLinkPath, targetPath) == 0 {
                        linkedCount += 1
                        freedBytes += group.fileSize
                    } else {
                        unlink(tempLinkPath)
                        failedCount += 1
                    }
                } else {
                    failedCount += 1
                }
            }
        }

        return DeduplicationResult(
            linkedCount: linkedCount,
            freedBytes: freedBytes,
            failedCount: failedCount
        )
    }

    // MARK: - 私有哈希计算辅助

    private func computePartialHash(for url: URL, size: Int64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let sampleSize = 4096
        var hasher = SHA256()

        // 头部
        let headData = (try? handle.read(upToCount: sampleSize)) ?? Data()
        hasher.update(data: headData)

        // 尾部
        if size > Int64(sampleSize * 2) {
            let tailOffset = UInt64(size - Int64(sampleSize))
            if (try? handle.seek(toOffset: tailOffset)) != nil {
                let tailData = (try? handle.read(upToCount: sampleSize)) ?? Data()
                hasher.update(data: tailData)
            }
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func computeFullSHA256(for url: URL) -> String? {
        guard let stream = InputStream(url: url) else { return nil }
        stream.open()
        defer { stream.close() }

        var hasher = SHA256()
        let bufferSize = 65536
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while stream.hasBytesAvailable {
            let bytesRead = stream.read(&buffer, maxLength: bufferSize)
            if bytesRead > 0 {
                hasher.update(data: Data(buffer[0..<bytesRead]))
            } else if bytesRead < 0 {
                return nil
            } else {
                break
            }
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

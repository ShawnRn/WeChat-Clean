import SwiftUI
import AppKit
import QuickLookThumbnailing
import ImageIO
import Observation

/// 缩略图响应式管理中心（消除 SwiftUI Table 对 onAppear 的依赖，支持请求去重、多级缓存与精确回调）
@Observable
@MainActor
public final class ThumbnailStore {
    public static let shared = ThumbnailStore()

    // 内存硬引用字典（LRU 辅助，防止全局频繁触发全量重绘）
    @ObservationIgnored
    public private(set) var thumbnails: [URL: NSImage] = [:]

    // 快速 NSCache（LRU 淘汰，避免大列表内存膨胀）
    @ObservationIgnored
    private let lruCache = NSCache<NSURL, NSImage>()

    // 正在进行的并发 Task 字典，防止同一个 URL 触发重复解码
    @ObservationIgnored
    private var inFlightTasks: [URL: Task<NSImage?, Never>] = [:]

    private init() {
        lruCache.countLimit = 1000
        lruCache.totalCostLimit = 80 * 1024 * 1024 // 80MB 内存上限
    }

    /// 同步获取缓存中的缩略图（若无则返回 nil）
    public func cachedImage(for url: URL) -> NSImage? {
        if let cached = lruCache.object(forKey: url as NSURL) {
            return cached
        }
        return thumbnails[url]
    }

    /// 现代 Swift 异步加载缩略图（支持并发请求合并去重，零闭包丢失风险）
    public func loadThumbnail(for item: WeChatFileItem, size: CGFloat = 32) async -> NSImage? {
        let url = item.url
        func logStore(_ msg: String) {
            let line = "\(Date()): [loadThumbnail] \(item.name): \(msg)\n"
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/wechat_thumb.log")) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            }
        }

        if let cached = cachedImage(for: url) {
            logStore("CACHE HIT")
            return cached
        }

        let ext = url.pathExtension.lowercased()
        let isImage = ["jpg", "jpeg", "png", "heic", "webp", "gif", "bmp", "tiff"].contains(ext)
        let isVideo = ["mp4", "mov", "m4v", "avi", "mkv"].contains(ext)
        let isDat = (ext == "dat")

        logStore("CALLED: ext=\(ext), isImage=\(isImage), isDat=\(isDat)")

        guard isImage || isVideo || isDat || item.thumbnailURL != nil else {
            logStore("GUARD REJECTED!")
            return nil
        }

        // 若已有正在进行的后台任务，直接复用其计算结果
        if let existing = inFlightTasks[url] {
            return await existing.value
        }

        let maxPixelSize = size * 2.0 // 支持 Retina 屏幕
        let targetURL = item.url
        let thumbHintURL = item.thumbnailURL

        let task = Task.detached(priority: .userInitiated) { () -> NSImage? in
            return await Self.decodeMedia(
                targetURL: targetURL,
                thumbHintURL: thumbHintURL,
                isDat: isDat,
                isImage: isImage,
                isVideo: isVideo,
                maxPixelSize: maxPixelSize,
                renderSize: size
            )
        }

        inFlightTasks[url] = task
        let result = await task.value
        inFlightTasks.removeValue(forKey: url)

        if let image = result {
            let cost = Int(image.size.width * image.size.height * 4)
            lruCache.setObject(image, forKey: url as NSURL, cost: cost)

            // 容量保护
            if thumbnails.count > 500 {
                thumbnails.removeAll(keepingCapacity: true)
            }
            thumbnails[url] = image
            QuickLookManager.shared.setImage(image, for: url)
        }

        return result
    }

    /// 兼容旧版同步调用（返回当前缓存）
    public func thumbnail(for item: WeChatFileItem, size: CGFloat = 32) -> NSImage? {
        return cachedImage(for: item.url)
    }

    /// 后台无阻塞解码流水线
    nonisolated private static func decodeMedia(
        targetURL: URL,
        thumbHintURL: URL?,
        isDat: Bool,
        isImage: Bool,
        isVideo: Bool,
        maxPixelSize: CGFloat,
        renderSize: CGFloat
    ) async -> NSImage? {
        // 策略 0: .dat 附件（微信 V2 AES+XOR 或 legacy XOR，自动寻找伴生 _t.dat）
        if isDat {
            if let image = WeChatDatDecoder.shared.decodeThumbnail(at: targetURL, maxPixelSize: maxPixelSize) {
                return image
            }
        }

        // 策略 1: 微信本地现存的 _thumb.jpg 或 hintURL 降采样
        if let directThumb = findDirectThumbnailURL(for: targetURL, hintURL: thumbHintURL),
           let image = downsampleImage(at: directThumb, maxPixelSize: maxPixelSize) {
            return image
        }

        // 策略 2: 普通图片文件直接低内存降采样
        if isImage, let image = downsampleImage(at: targetURL, maxPixelSize: maxPixelSize) {
            return image
        }

        // 策略 3: 视频文件通过 QLThumbnailGenerator 抽帧
        if isVideo {
            let request = QLThumbnailGenerator.Request(
                fileAt: targetURL,
                size: CGSize(width: maxPixelSize, height: maxPixelSize),
                scale: 2.0,
                representationTypes: .thumbnail
            )

            let videoThumb: NSImage? = await withCheckedContinuation { continuation in
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                    if let cg = rep?.cgImage {
                        continuation.resume(returning: NSImage(cgImage: cg, size: NSSize(width: renderSize, height: renderSize)))
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
            return videoThumb
        }

        return nil
    }

    /// 探测伴生缩略图
    nonisolated private static func findDirectThumbnailURL(for url: URL, hintURL: URL?) -> URL? {
        let fm = FileManager.default
        if let hint = hintURL, fm.fileExists(atPath: hint.path) {
            return hint
        }

        let dir = url.deletingLastPathComponent()
        let baseName = url.deletingPathExtension().lastPathComponent

        let candidate1 = dir.appendingPathComponent("\(baseName)_thumb.jpg")
        if fm.fileExists(atPath: candidate1.path) {
            return candidate1
        }

        if baseName.hasSuffix("_raw") {
            let cleanBase = String(baseName.dropLast(4))
            let candidate2 = dir.appendingPathComponent("\(cleanBase)_thumb.jpg")
            if fm.fileExists(atPath: candidate2.path) {
                return candidate2
            }
        }

        return nil
    }

    /// ImageIO 高性能降采样
    nonisolated private static func downsampleImage(at url: URL, maxPixelSize: CGFloat) -> NSImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return nil }

        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) else {
            return nil
        }
        return NSImage(cgImage: thumbnail, size: .zero)
    }
}

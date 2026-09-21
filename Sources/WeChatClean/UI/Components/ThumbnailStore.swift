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

    // 内存硬引用字典（驱动 SwiftUI 视图响应式重绘）
    public private(set) var thumbnails: [URL: NSImage] = [:]

    // 快速 NSCache（LRU 淘汰，避免大列表内存膨胀）
    @ObservationIgnored
    private let lruCache = NSCache<NSURL, NSImage>()

    // 正在进行的并发请求集合，防止同一个 URL 触发重复解码
    @ObservationIgnored
    private var activeRequests = Set<URL>()

    // 回调列表：当后台解码完成时，通知所有等待该 URL 的 View 更新其 @State
    @ObservationIgnored
    private var callbacks: [URL: [(@MainActor (NSImage) -> Void)]] = [:]

    private init() {
        lruCache.countLimit = 800
        lruCache.totalCostLimit = 60 * 1024 * 1024 // 60MB 内存上限
    }

    /// 同步获取缓存中的缩略图（若无则返回 nil）
    public func cachedImage(for url: URL) -> NSImage? {
        if let cached = lruCache.object(forKey: url as NSURL) {
            return cached
        }
        return thumbnails[url]
    }

    /// 异步请求缩略图并支持完成回调（精准驱动具体单元格的 @State 更新）
    public func requestThumbnail(
        for item: WeChatFileItem,
        size: CGFloat = 32,
        completion: (@MainActor @escaping (NSImage) -> Void)
    ) {
        let url = item.url

        // 1. 若已有缓存，直接同步返回
        if let cached = cachedImage(for: url) {
            completion(cached)
            return
        }

        // 2. 检查是否为可生成缩略图的媒体类型
        let ext = url.pathExtension.lowercased()
        let isImage = ["jpg", "jpeg", "png", "heic", "webp", "gif", "bmp", "tiff"].contains(ext)
        let isVideo = ["mp4", "mov", "m4v", "avi", "mkv"].contains(ext)
        let isDat = (ext == "dat")

        guard isImage || isVideo || isDat || item.thumbnailURL != nil else {
            return
        }

        // 3. 注册回调
        callbacks[url, default: []].append(completion)

        // 4. 避免对同一 URL 重复启动后台任务
        guard !activeRequests.contains(url) else {
            return
        }
        activeRequests.insert(url)

        let maxPixelSize = size * 2.0 // 支持 Retina 屏幕高清缩放
        let targetURL = item.url
        let thumbHintURL = item.thumbnailURL

        // 5. 后台并发异步解码
        Task.detached(priority: .userInitiated) { [weak self] in
            let decodedImage = await Self.decodeMedia(
                targetURL: targetURL,
                thumbHintURL: thumbHintURL,
                isDat: isDat,
                isImage: isImage,
                isVideo: isVideo,
                maxPixelSize: maxPixelSize,
                renderSize: size
            )

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.activeRequests.remove(url)

                if let image = decodedImage {
                    let cost = Int(image.size.width * image.size.height * 4)
                    self.lruCache.setObject(image, forKey: url as NSURL, cost: cost)

                    // 字典容量保护，防止长时间使用造成无限增长
                    if self.thumbnails.count > 500 {
                        self.thumbnails.removeAll(keepingCapacity: true)
                    }
                    self.thumbnails[url] = image
                    QuickLookManager.shared.setImage(image, for: url)

                    // 触发所有等待该 URL 的回调
                    if let cbs = self.callbacks.removeValue(forKey: url) {
                        for cb in cbs {
                            cb(image)
                        }
                    }
                } else {
                    self.callbacks.removeValue(forKey: url)
                }
            }
        }
    }

    /// 兼容旧版同步调用（返回当前缓存或启动后台加载）
    public func thumbnail(for item: WeChatFileItem, size: CGFloat = 32) -> NSImage? {
        if let cached = cachedImage(for: item.url) {
            return cached
        }
        requestThumbnail(for: item, size: size) { _ in }
        return nil
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

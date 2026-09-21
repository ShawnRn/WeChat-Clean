import SwiftUI
import AppKit

/// 缩略图内存缓存（兼容代理层）
public final class ThumbnailCache: @unchecked Sendable {
    public static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, NSImage>()

    private init() {
        cache.countLimit = 600
        cache.totalCostLimit = 40 * 1024 * 1024
    }

    public func image(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    public func setImage(_ image: NSImage, for url: URL) {
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }
}

/// 媒体文件缩略图组件（响应式按需加载，彻底解决 SwiftUI Table 内部单元格生命周期与异步重绘问题）
@MainActor
public struct MediaThumbnailView: View {
    let item: WeChatFileItem
    let size: CGFloat

    @State private var thumbnail: NSImage?

    public init(item: WeChatFileItem, size: CGFloat = 32) {
        self.item = item
        self.size = size
        _thumbnail = State(initialValue: ThumbnailStore.shared.cachedImage(for: item.url))
    }

    public var body: some View {
        let storeImage = ThumbnailStore.shared.thumbnails[item.url]
        let displayImage = storeImage ?? thumbnail ?? ThumbnailStore.shared.cachedImage(for: item.url)
        let _ = triggerLoadIfNeeded(currentImage: displayImage)

        ZStack {
            if let image = displayImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                    }

                // 视频左下角微型角标
                if item.category == .video {
                    VStack {
                        Spacer()
                        HStack {
                            Image(systemName: "play.fill")
                                .font(.system(size: 7))
                                .foregroundStyle(.white)
                                .padding(2)
                                .background(Circle().fill(.black.opacity(0.6)))
                            Spacer()
                        }
                    }
                    .padding(2)
                    .frame(width: size, height: size)
                }
            } else {
                placeholderView
            }
        }
        .frame(width: size, height: size)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        QuickLookManager.shared.setFrame(proxy.frame(in: .global), for: item.url)
                    }
                    .onChange(of: proxy.frame(in: .global)) { _, newFrame in
                        QuickLookManager.shared.setFrame(newFrame, for: item.url)
                    }
            }
        )
        .onAppear {
            triggerLoadIfNeeded(currentImage: displayImage)
        }
        .onChange(of: item.url) { _, newURL in
            self.thumbnail = ThumbnailStore.shared.cachedImage(for: newURL)
            triggerLoadIfNeeded(currentImage: self.thumbnail)
        }
    }

    // MARK: - 触发异步解码流水线
    private func triggerLoadIfNeeded(currentImage: NSImage?) {
        guard currentImage == nil else { return }
        ThumbnailStore.shared.requestThumbnail(for: item, size: size) { [self] image in
            // 异步回调到达时，直接修改 @State，必定强制 SwiftUI 单元格重绘
            self.thumbnail = image
        }
    }

    // MARK: - 占位图标
    @ViewBuilder
    private var placeholderView: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(categoryBgColor.opacity(0.12))
            .overlay {
                Image(systemName: item.category.systemImage)
                    .font(.system(size: size * 0.44))
                    .foregroundStyle(categoryBgColor)
            }
            .frame(width: size, height: size)
    }

    private var categoryBgColor: Color {
        switch item.category {
        case .video: return .red
        case .attach: return .green
        case .largeFiles: return .orange
        case .file: return .blue
        case .cache: return .gray
        case .duplicates: return .purple
        case .all: return .secondary
        }
    }
}

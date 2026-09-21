import SwiftUI
import AppKit

/// 媒体文件缩略图组件（极致性能，纯本地精准重绘，零全局观察者污染，120fps 满帧滚动）
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
        ZStack {
            if let image = thumbnail {
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
        .task(id: item.url) {
            let line = "\(Date()): [ViewTask] \(item.name): START, thumbnail=\(thumbnail != nil)\n"
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/wechat_thumb.log")) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            }

            // 异步按需加载，仅当无缓存时发起
            if thumbnail == nil {
                if let cached = ThumbnailStore.shared.cachedImage(for: item.url) {
                    self.thumbnail = cached
                } else {
                    let loaded = await ThumbnailStore.shared.loadThumbnail(for: item, size: size)
                    let finishLine = "\(Date()): [ViewTask] \(item.name): LOADED=\(loaded != nil)\n"
                    if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/wechat_thumb.log")) {
                        _ = try? handle.seekToEnd()
                        try? handle.write(contentsOf: Data(finishLine.utf8))
                        try? handle.close()
                    }
                    if let loaded {
                        self.thumbnail = loaded
                    }
                }
            }
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

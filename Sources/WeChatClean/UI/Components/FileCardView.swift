import SwiftUI
import QuickLook

public struct FileCardView: View {
    @Environment(\.colorScheme) private var colorScheme
    let item: WeChatFileItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onPreview: () -> Void
    let onShowInFinder: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    public init(
        item: WeChatFileItem,
        isSelected: Bool,
        onSelect: @escaping () -> Void,
        onPreview: @escaping () -> Void,
        onShowInFinder: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.item = item
        self.isSelected = isSelected
        self.onSelect = onSelect
        self.onPreview = onPreview
        self.onShowInFinder = onShowInFinder
        self.onDelete = onDelete
    }

    public var body: some View {
        HStack(spacing: 12) {
            // 1. 图标或缩略图 (40x40 紧凑尺寸)
            thumbnailView
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            // 2. 文件信息
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)

                    if item.isHardlink {
                        Image(systemName: "link")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .help("APFS 硬链接副本")
                    }
                }

                HStack(spacing: 8) {
                    Text(item.category.rawValue)
                        .font(.system(size: 10))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                        .foregroundStyle(.secondary)

                    Text(item.formattedDate)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // 3. 大小与快捷操作
            HStack(spacing: 12) {
                Text(item.formattedSize)
                    .font(.system(size: 12, weight: item.size >= 100 * 1024 * 1024 ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(item.size >= 100 * 1024 * 1024 ? Color.primary : Color.secondary)

                if isHovered || isSelected {
                    HStack(spacing: 4) {
                        Button(action: onPreview) {
                            Image(systemName: "eye")
                                .font(.system(size: 11))
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(.secondary.opacity(0.1)))
                        }
                        .buttonStyle(.plain)
                        .help("预览 (空格)")

                        Button(action: onShowInFinder) {
                            Image(systemName: "folder")
                                .font(.system(size: 11))
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(.secondary.opacity(0.1)))
                        }
                        .buttonStyle(.plain)
                        .help("在 Finder 中显示")

                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundStyle(.red.opacity(0.8))
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(.red.opacity(0.1)))
                        }
                        .buttonStyle(.plain)
                        .help("移入废纸篓")
                    }
                    .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(colorScheme == .dark ? 0.2 : 0.1) : (isHovered ? Color.primary.opacity(0.03) : Color.clear))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isSelected ? Color.accentColor.opacity(0.6) : (isHovered ? Color.primary.opacity(0.08) : Color.clear),
                    lineWidth: 1
                )
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .contextMenu {
            Button("快速预览 (空格)", action: onPreview)
            Button("在 Finder 中显示", action: onShowInFinder)
            Divider()
            Button("移入废纸篓", role: .destructive, action: onDelete)
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumb = item.thumbnailURL, let nsImage = NSImage(contentsOf: thumb) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color.primary.opacity(0.04)
                Image(systemName: iconName(for: item.category))
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func iconName(for category: WeChatCategory) -> String {
        switch category {
        case .video: return "film"
        case .file: return "doc"
        case .attach: return "photo"
        case .cache: return "archivebox"
        default: return "doc"
        }
    }
}

import SwiftUI

public struct InspectorView: View {
    let item: WeChatFileItem
    @Bindable var state: AppState
    let onClose: () -> Void

    public init(item: WeChatFileItem, state: AppState, onClose: @escaping () -> Void) {
        self.item = item
        self.state = state
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 顶部标题栏与关闭按钮
            HStack {
                Text("文件详情")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(.secondary.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 1. 大封面展示
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                            .frame(height: 180)

                        if let thumb = item.thumbnailURL, let nsImage = NSImage(contentsOf: thumb) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 170)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .shadow(color: .black.opacity(0.1), radius: 6, x: 0, y: 3)
                        } else {
                            VStack(spacing: 8) {
                                Image(systemName: iconName(for: item.category))
                                    .font(.system(size: 48, weight: .light))
                                    .foregroundStyle(.secondary)
                                Text(item.name.components(separatedBy: ".").last?.uppercased() ?? "FILE")
                                    .font(.system(size: 12, weight: .bold).monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    // 2. 文件名与突出大小
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name)
                            .font(.system(size: 15, weight: .bold))
                            .textSelection(.enabled)

                        Text(item.formattedSize)
                            .font(.system(size: 22, weight: .heavy).monospacedDigit())
                            .foregroundStyle(item.size >= 100 * 1024 * 1024 ? .red : .primary)
                    }

                    // 3. 视频缩略图保护指示卡片
                    if item.category == .video {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.green)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("缩略图保留保护已开启")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.green)

                                Text("删除此视频后，微信聊天记录中将完整保留封面缩略图，不会出现断裂黑块。")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.green.opacity(0.08)))
                    }

                    // 4. 详细元数据
                    VStack(alignment: .leading, spacing: 10) {
                        detailRow(title: "分类", value: item.category.rawValue)
                        detailRow(title: "修改时间", value: item.formattedDate)

                        if item.isHardlink {
                            HStack {
                                Text("存储属性")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 60, alignment: .leading)
                                Label("APFS 硬链接副本 (零额外占用)", systemImage: "link")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.purple)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("物理路径")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Text(item.url.path)
                                .font(.system(size: 10).monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.03)))

                    // 5. 操作按钮
                    VStack(spacing: 8) {
                        Button {
                            state.previewURL = item.url
                        } label: {
                            HStack {
                                Image(systemName: "eye")
                                Text("快速预览 (空格)")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([item.url])
                        } label: {
                            HStack {
                                Image(systemName: "folder")
                                Text("在 Finder 中定位")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                        }
                        .buttonStyle(.bordered)

                        Button(role: .destructive) {
                            state.selectedItemIDs = [item.id]
                            state.cleanSelected(preserveThumbnails: true)
                        } label: {
                            HStack {
                                Image(systemName: "trash.fill")
                                Text("移入系统废纸篓")
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(.red))
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .shadow(color: .red.opacity(0.3), radius: 6, x: 0, y: 2)
                    }
                    .padding(.top, 8)
                }
                .padding(18)
            }
        }
        .frame(width: 340)
        .background(.ultraThinMaterial)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(width: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 15, x: -5, y: 0)
    }

    private func detailRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }

    private func iconName(for category: WeChatCategory) -> String {
        switch category {
        case .video: return "film"
        case .file: return "doc.text"
        case .attach: return "photo"
        case .cache: return "archivebox"
        default: return "doc"
        }
    }
}

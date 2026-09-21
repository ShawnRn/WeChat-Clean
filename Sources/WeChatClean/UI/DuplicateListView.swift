import SwiftUI

public struct DuplicateListView: View {
    @Bindable var state: AppState

    public init(state: AppState) {
        self.state = state
    }

    private var totalReclaimable: Int64 {
        state.duplicateGroups.reduce(0) { $0 + $1.reclaimableSize }
    }

    public var body: some View {
        Group {
            if state.isDeduplicating {
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("正在进行两阶段哈希比对与 Inode 查重...")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .top, spacing: 0) {
                    unifiedHeaderBanner
                }
            } else if state.duplicateGroups.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text("未发现重复文件")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("当前微信数据中没有跨群重复转发的大文件，已处于最佳存储状态。")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .top, spacing: 0) {
                    unifiedHeaderBanner
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(state.duplicateGroups) { group in
                            duplicateGroupCard(group)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    unifiedHeaderBanner
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var unifiedHeaderBanner: some View {
        VStack(spacing: 0) {
            // 顶部横幅
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.purple)
                        Text("APFS 零损失硬链接去重")
                            .font(.system(size: 16, weight: .bold))
                    }

                    Text("通过 APFS 硬链接，多个会话中转发的同一大文件将合并底层存储。去重后微信内各处仍然完全正常打开，物理磁盘空间直接归一。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                if totalReclaimable > 0 {
                    Button {
                        state.applyHardlinkDeduplication()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "bolt.fill")
                            Text("一键释放 \(ByteCountFormatter.string(fromByteCount: totalReclaimable, countStyle: .file))")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(.purple))
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .shadow(color: .purple.opacity(0.35), radius: 8, x: 0, y: 3)
                }
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 12).fill(.purple.opacity(0.06)))
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()
        }
        .background(.ultraThinMaterial)
    }

    private func duplicateGroupCard(_ group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.purple)
                    Text("重复组 (共 \(group.items.count) 个副本)")
                        .font(.system(size: 13, weight: .bold))
                }

                Spacer()

                Text("单文件: \(ByteCountFormatter.string(fromByteCount: group.fileSize, countStyle: .file))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)

                if group.reclaimableSize > 0 {
                    Text("可节省 \(group.formattedReclaimableSize)")
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.orange.opacity(0.12)))
                }
            }

            Divider()

            VStack(spacing: 6) {
                ForEach(group.items) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.isHardlink ? "link" : "doc")
                            .font(.system(size: 11))
                            .foregroundStyle(item.isHardlink ? .purple : .secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(item.url.deletingLastPathComponent().path)
                                .font(.system(size: 10).monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        if item.isHardlink {
                            Text("已硬链接")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.purple)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.purple.opacity(0.12)))
                        }

                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([item.url])
                        } label: {
                            Image(systemName: "folder")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("在 Finder 中显示")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.02)))
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor).opacity(0.7)))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }
}

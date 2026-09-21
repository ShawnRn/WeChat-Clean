import SwiftUI
import QuickLook
import Quartz

public struct FileListView: View {
    @Bindable var state: AppState
    @State private var keyMonitor: Any?

    public init(state: AppState) {
        self.state = state
    }

    private var firstSelectedURL: URL? {
        guard let firstID = state.selectedItemIDs.first else { return nil }
        return state.itemMap[firstID]?.url
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                // 1. 顶部 Header (类似 MotrixMac TaskListHeader，带呼吸感)
                headerView
                    .padding(.horizontal, 22)
                    .padding(.top, 24)
                    .padding(.bottom, 12)

                Divider()
                    .padding(.horizontal, 22)

                // 2. 列表内容
                if state.scanProgress.isScanning && state.displayedItems.isEmpty {
                    loadingView
                } else if state.displayedItems.isEmpty {
                    emptyView
                } else {
                    tableViewContent
                }
            }

            // 3. 底部悬浮操作条 (Floating Action Bar)
            if !state.selectedItemIDs.isEmpty {
                floatingActionBar
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            setupKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
        }
        .onChange(of: state.selectedItemIDs) { _, newIDs in
            state.selectedTotalSize = newIDs.compactMap { state.itemMap[$0]?.size }.reduce(0, +)
            QuickLookManager.shared.updatePreviewIfVisible(for: firstSelectedURL)
        }
        .onChange(of: state.tableSortOrder) { oldOrder, newOrder in
            if let first = newOrder.first, first.keyPath == \WeChatFileItem.modificationDate {
                if oldOrder.first?.keyPath != \WeChatFileItem.modificationDate && first.order == .forward {
                    state.tableSortOrder = [KeyPathComparator(\WeChatFileItem.modificationDate, order: .reverse)]
                    return
                }
            }
            state.scheduleFilterAndSort()
        }
    }

    // MARK: - 键盘快捷键监听 (⌘+A 全选, ⌘+Delete 移入废纸篓, 空格预览, ESC 取消选择)
    private func setupKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 如果焦点在文本框输入（如搜索框、修改备注框），不拦截快捷键
            if let firstResponder = NSApp.keyWindow?.firstResponder,
               firstResponder is NSTextView || firstResponder is NSTextField {
                return event
            }

            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])

            // 1. ⌘ + A 全选当前列表 (keyCode 0 或字符 'a')
            if flags == .command && (event.charactersIgnoringModifiers?.lowercased() == "a" || event.keyCode == 0) {
                state.selectAllFiltered()
                return nil
            }

            // 2. ⌘ + Backspace (或 Delete) 移入废纸篓 (keyCode 51 为 delete, 117 为 forward delete)
            if flags == .command && (event.keyCode == 51 || event.keyCode == 117) {
                if !state.selectedItemIDs.isEmpty {
                    state.cleanSelected(preserveThumbnails: true)
                    return nil
                }
            }

            // 3. keyCode 49 为空格键 (QuickLook 预览)
            if event.keyCode == 49 {
                if let url = firstSelectedURL {
                    QuickLookManager.shared.togglePreview(for: url)
                    return nil
                }
            }

            // 4. ESC 键清除选择 (keyCode 53)
            if event.keyCode == 53 {
                if !state.selectedItemIDs.isEmpty {
                    state.clearSelection()
                    return nil
                }
            }

            return event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    // MARK: - 顶部 Header (MotrixMac 风格)
    private var headerView: some View {
        HStack(alignment: .center, spacing: 14) {
            if state.drillDownSession != nil {
                Button {
                    state.exitSessionDrillDown()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .padding(6)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("返回会话列表")
            }

            VStack(alignment: .leading, spacing: 3) {
                if let drill = state.drillDownSession {
                    HStack(spacing: 6) {
                        Text(drill.effectiveName)
                            .font(.system(size: 20, weight: .bold))
                        Text("会话附件")
                            .font(.system(size: 11))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                            .foregroundStyle(Color.accentColor)
                    }
                } else {
                    HStack(spacing: 8) {
                        Text(state.selectedCategory.rawValue)
                            .font(.system(size: 20, weight: .bold))

                        if let contactFilter = state.contactFilter {
                            HStack(spacing: 4) {
                                Text("联系人: \(state.sessionDisplayName(for: contactFilter))")
                                    .font(.system(size: 11, weight: .medium))
                                Button {
                                    state.contactFilter = nil
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                            .foregroundStyle(Color.accentColor)
                        }
                    }
                }

                Text("共 \(state.filteredItemCount) 项 · \(ByteCountFormatter.string(fromByteCount: state.currentCategorySize, countStyle: .file))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // 搜索框
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                TextField("搜索文件名...", text: $state.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 130)

                if !state.searchText.isEmpty {
                    Button {
                        state.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))

            // 大小筛选
            Picker("大小", selection: $state.sizeFilter) {
                ForEach(SizeFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 135)
        }
    }

    // MARK: - 表格内容 (支持点击表头原生排序)
    private var tableViewContent: some View {
        VStack(spacing: 0) {
            Table(state.displayedItems, selection: $state.selectedItemIDs, sortOrder: $state.tableSortOrder) {
                // 1. 文件名列（可点击表头按名称排序）
                TableColumn("文件名", value: \.name) { item in
                    HStack(spacing: 10) {
                        MediaThumbnailView(item: item, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(item.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                if item.isHardlink {
                                    Image(systemName: "link")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.purple)
                                        .help("APFS 硬链接副本")
                                }
                            }

                            HStack(spacing: 4) {
                                if let hash = item.sessionHash {
                                    Text(state.sessionDisplayName(for: hash))
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(Color.accentColor.opacity(0.8))
                                    Text("·")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                                Text(relativeDisplayPath(for: item.url))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .contextMenu {
                        contextMenu(for: item)
                    }
                }
                .width(min: 240, ideal: 360)

                // 2. 大小列（可点击表头按大小升序/降序）
                TableColumn("大小", value: \.size) { item in
                    Text(item.formattedSize)
                        .font(.system(size: 12, weight: item.size >= 100 * 1024 * 1024 ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(item.size >= 100 * 1024 * 1024 ? Color.primary : Color.secondary)
                }
                .width(min: 80, ideal: 90, max: 110)

                // 3. 分类列（可点击表头按分类排序）
                TableColumn("分类", value: \.category.rawValue) { item in
                    Text(item.category.rawValue)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .width(min: 65, ideal: 75, max: 90)

                // 4. 修改时间列（可点击表头按时间升序/降序）
                TableColumn("修改时间", value: \.modificationDate) { item in
                    Text(item.formattedDate)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .width(min: 110, ideal: 125, max: 140)
            }

            if state.filteredItemCount > state.displayedItems.count {
                HStack(spacing: 8) {
                    Text("已显示前 \(state.displayedItems.count) 项，共 \(state.filteredItemCount) 项 (\(ByteCountFormatter.string(fromByteCount: state.currentCategorySize, countStyle: .file)))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Button("加载更多 500 项") {
                        state.displayLimit += 500
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)

                    Button("加载全部") {
                        state.displayLimit = max(state.filteredItemCount, 1000)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }

    // MARK: - 悬浮操作条 (Floating Action Bar, 对齐 Pearcleaner 胶囊风格)
    private var floatingActionBar: some View {
        HStack(spacing: 12) {
            let isAllSelected = (state.selectedItemIDs.count >= state.filteredItemCount && state.filteredItemCount > 0)
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.tint)
                Text(isAllSelected ? "已选全部 \(state.selectedItemIDs.count) 项" : "已选 \(state.selectedItemIDs.count) 项")
                    .font(.system(size: 12, weight: .semibold))
                Text("(\(ByteCountFormatter.string(fromByteCount: state.selectedTotalSize, countStyle: .file)))")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Divider().frame(height: 12)

            // 如果当前只选择了当前页面的项目，且总项目数更多，提供一键全选全部项目按钮
            if !isAllSelected && state.filteredItemCount > state.displayedItems.count {
                Button {
                    state.selectAllCategory()
                } label: {
                    Text("选择全部 \(state.filteredItemCount) 项 (\(ByteCountFormatter.string(fromByteCount: state.currentCategorySize, countStyle: .file)))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)

                Divider().frame(height: 12)
            }

            Button(state.selectedItemIDs.isEmpty ? "全选当前页" : "取消选择") {
                if state.selectedItemIDs.isEmpty {
                    state.selectAllFiltered()
                } else {
                    state.clearSelection()
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)

            Button(role: .destructive) {
                state.cleanSelected(preserveThumbnails: true)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "trash")
                    Text("移入废纸篓")
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.accentColor))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
                .overlay {
                    Capsule()
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }
        }
        .padding(.horizontal, 28)
    }

    private func relativeDisplayPath(for url: URL) -> String {
        let path = url.path
        if let range = path.range(of: "xwechat_files/") {
            let sub = String(path[range.upperBound...])
            let parts = sub.split(separator: "/", maxSplits: 1)
            if parts.count > 1 {
                return String(parts[1])
            }
            return sub
        }
        return url.deletingLastPathComponent().lastPathComponent
    }

    // MARK: - 辅助组件
    @ViewBuilder
    private func fileIcon(for item: WeChatFileItem) -> some View {
        Image(systemName: iconName(for: item.category))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(width: 16)
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

    @ViewBuilder
    private func contextMenu(for item: WeChatFileItem) -> some View {
        Button("快速预览 (空格)") {
            QuickLookManager.shared.togglePreview(for: item.url)
        }
        Button("在 Finder 中显示") {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        }
        Divider()
        Button("移入废纸篓", role: .destructive) {
            state.selectedItemIDs = [item.id]
            state.cleanSelected(preserveThumbnails: true)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text(state.scanProgress.statusMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("没有匹配的文件")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Text("当前筛选条件下未发现文件。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

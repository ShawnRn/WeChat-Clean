import SwiftUI
import QuickLook
import Quartz

/// 文件列表视图（顶上一体化沉浸式毛玻璃 Header，内容穿透磨砂模糊，支持原生多选、排序、QuickLook 与分页）
public struct FileListView: View {
    @Bindable var state: AppState
    @State private var keyMonitor: Any?
    @State private var hoveredItemID: String? = nil
    @State private var lastClickedIndex: Int? = nil

    public init(state: AppState) {
        self.state = state
    }

    private var firstSelectedURL: URL? {
        guard let firstID = state.selectedItemIDs.first else { return nil }
        return state.itemMap[firstID]?.url
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            // 1. 列表核心内容与顶上一体化毛玻璃 Header (利用 safeAreaInset 实现全尺寸穿透滚动与整块磨砂模糊)
            if state.scanProgress.isScanning && state.displayedItems.isEmpty {
                loadingView
                    .safeAreaInset(edge: .top, spacing: 0) {
                        unifiedHeaderView
                    }
            } else if state.displayedItems.isEmpty {
                emptyView
                    .safeAreaInset(edge: .top, spacing: 0) {
                        unifiedHeaderView
                    }
            } else {
                scrollableContentList
                    .safeAreaInset(edge: .top, spacing: 0) {
                        unifiedHeaderView
                    }
            }

            // 2. 底部悬浮操作条 (Floating Action Bar, 对齐 Pearcleaner 胶囊风格)
            if !state.selectedItemIDs.isEmpty {
                floatingActionBar
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            setupKeyMonitor()
            QuickLookManager.shared.onNavigateNext = {
                state.selectNextItem()
            }
            QuickLookManager.shared.onNavigatePrevious = {
                state.selectPreviousItem()
            }
        }
        .onDisappear {
            removeKeyMonitor()
            QuickLookManager.shared.onNavigateNext = nil
            QuickLookManager.shared.onNavigatePrevious = nil
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

    // MARK: - 顶上一体化沉浸式毛玻璃 Header (整块超细磨砂模糊，彻底消除断层)
    private var unifiedHeaderView: some View {
        VStack(spacing: 0) {
            // 1. 顶部 Header 标题与工具栏
            headerTopBar
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 10)

            // 2. 表头列名行 (支持点击列名切换正序/倒序，指示箭头随动)
            tableHeaderRow
                .padding(.horizontal, 22)
                .padding(.vertical, 7)

            // 3. 底部分隔线 (精细边框)
            Divider()
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - 顶部 Header 工具栏
    private var headerTopBar: some View {
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

            // 提取密钥快捷入口 (未配置密钥时显著提示)
            if !WeChatContactManager.shared.hasKey {
                Button {
                    state.showDatabaseKeySheet = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                        Text("提取密钥显示联系人")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("一键提取微信数据库密钥以显示联系人真实昵称与群名")
            }

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

    // MARK: - 表头列名行 (点击表头排序)
    private var tableHeaderRow: some View {
        HStack(spacing: 12) {
            // 1. 文件名表头 (对齐下方缩略图与文字)
            Button {
                toggleSortName()
            } label: {
                HStack(spacing: 4) {
                    Text("文件名")
                        .font(.system(size: 11, weight: .semibold))
                    let sortInfo = currentSortIndicator(for: \WeChatFileItem.name)
                    if sortInfo.isActive {
                        Image(systemName: sortInfo.isAscending ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                }
                .foregroundStyle(isCurrentSort(for: \WeChatFileItem.name) ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 38) // 避让每行左侧复选框与缩略图对齐

            // 2. 大小表头
            Button {
                toggleSortSize()
            } label: {
                HStack(spacing: 4) {
                    Text("大小")
                        .font(.system(size: 11, weight: .semibold))
                    let sortInfo = currentSortIndicator(for: \WeChatFileItem.size)
                    if sortInfo.isActive {
                        Image(systemName: sortInfo.isAscending ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                }
                .foregroundStyle(isCurrentSort(for: \WeChatFileItem.size) ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 90, alignment: .trailing)

            // 3. 分类表头
            Button {
                toggleSortCategory()
            } label: {
                HStack(spacing: 4) {
                    Text("分类")
                        .font(.system(size: 11, weight: .semibold))
                    let sortInfo = currentSortIndicator(for: \WeChatFileItem.category.rawValue)
                    if sortInfo.isActive {
                        Image(systemName: sortInfo.isAscending ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                }
                .foregroundStyle(isCurrentSort(for: \WeChatFileItem.category.rawValue) ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 80, alignment: .leading)
            .padding(.leading, 12)

            // 4. 修改时间表头
            Button {
                toggleSortDate()
            } label: {
                HStack(spacing: 4) {
                    Text("修改时间")
                        .font(.system(size: 11, weight: .semibold))
                    let sortInfo = currentSortIndicator(for: \WeChatFileItem.modificationDate)
                    if sortInfo.isActive {
                        Image(systemName: sortInfo.isAscending ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                }
                .foregroundStyle(isCurrentSort(for: \WeChatFileItem.modificationDate) ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 125, alignment: .trailing)
            .padding(.trailing, 10)
        }
    }

    // MARK: - 可穿透滚动的列表内容 (内容平滑滑入整块毛玻璃 Header 下方)
    private var scrollableContentList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(state.displayedItems.enumerated()), id: \.element.id) { index, item in
                        fileRowView(item: item, index: index)
                            .id(item.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 70) // 避让底部悬浮胶囊

                // 底部加载更多控制器
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
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
                }
            }
            .onChange(of: state.selectedItemIDs) { _, newIDs in
                if let firstID = newIDs.first {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        proxy.scrollTo(firstID, anchor: nil)
                    }
                }
            }
        }
    }

    // MARK: - 单行文件单元格 (与表头严格像素级对齐，智能识别真实格式)
    private func fileRowView(item: WeChatFileItem, index: Int) -> some View {
        let isSelected = state.selectedItemIDs.contains(item.id)
        let isHovered = (hoveredItemID == item.id)
        let realType = (item.url.pathExtension.lowercased() == "dat") ? WeChatDatDecoder.shared.detectRealTypeCached(at: item.url) : .unknown

        // 若已解密出真实格式，主名称以明文格式显示 (如 xxx.jpg / xxx.png)
        let displayName: String = {
            if realType != .unknown && item.name.lowercased().hasSuffix(".dat") {
                let base = (item.name as NSString).deletingPathExtension
                return "\(base).\(realType.fileExtension)"
            }
            return item.name
        }()

        return HStack(spacing: 12) {
            // 1. 选择勾选钮与缩略图及名称
            HStack(spacing: 10) {
                Button {
                    toggleSelection(for: item, index: index)
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.3))
                }
                .buttonStyle(.plain)

                MediaThumbnailView(item: item, size: 28)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(displayName)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if realType != .unknown {
                            Text(realType.rawValue)
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        }

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
                                .foregroundStyle(Color.accentColor.opacity(0.85))
                            Text("·")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        if realType != .unknown && item.name.lowercased().hasSuffix(".dat") {
                            Text("已解密")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.green.opacity(0.85))
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
            .frame(maxWidth: .infinity, alignment: .leading)

            // 2. 大小
            Text(item.formattedSize)
                .font(.system(size: 12, weight: item.size >= 100 * 1024 * 1024 ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(item.size >= 100 * 1024 * 1024 ? Color.primary : Color.secondary)
                .frame(width: 90, alignment: .trailing)

            // 3. 分类 (若为解密媒体则显示明确类型如 JPEG 图像)
            Text(realType != .unknown ? realType.localizedDescription : item.category.rawValue)
                .font(.system(size: 11))
                .foregroundStyle(realType != .unknown ? Color.accentColor : .secondary)
                .frame(width: 80, alignment: .leading)
                .padding(.leading, 12)

            // 4. 修改时间
            Text(item.formattedDate)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 125, alignment: .trailing)
                .padding(.trailing, 10)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : (isHovered ? Color.primary.opacity(0.04) : Color.clear))
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                hoveredItemID = item.id
            } else if hoveredItemID == item.id {
                hoveredItemID = nil
            }
        }
        .onTapGesture(count: 2) {
            // 双击快速调用空格预览
            QuickLookManager.shared.togglePreview(for: item.url)
        }
        .onTapGesture {
            handleRowClick(item: item, index: index)
        }
        .contextMenu {
            contextMenu(for: item)
        }
    }

    // MARK: - 点击选择逻辑 (支持 Shift 连续多选与 ⌘ 多选)
    private func handleRowClick(item: WeChatFileItem, index: Int) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            toggleSelection(for: item, index: index)
        } else if flags.contains(.shift), let last = lastClickedIndex {
            let start = min(last, index)
            let end = max(last, index)
            let rangeItems = state.displayedItems[start...end]
            for it in rangeItems {
                state.selectedItemIDs.insert(it.id)
            }
        } else {
            state.selectedItemIDs = [item.id]
            lastClickedIndex = index
        }
    }

    private func toggleSelection(for item: WeChatFileItem, index: Int) {
        if state.selectedItemIDs.contains(item.id) {
            state.selectedItemIDs.remove(item.id)
        } else {
            state.selectedItemIDs.insert(item.id)
        }
        lastClickedIndex = index
    }

    // MARK: - 排序状态辅助 (符合 Swift 6 严格并发模型)
    private func isCurrentSort(for keyPath: PartialKeyPath<WeChatFileItem>) -> Bool {
        guard let first = state.tableSortOrder.first else { return false }
        return first.keyPath == keyPath
    }

    private func currentSortIndicator(for keyPath: PartialKeyPath<WeChatFileItem>) -> (isActive: Bool, isAscending: Bool) {
        guard let first = state.tableSortOrder.first, first.keyPath == keyPath else {
            return (false, false)
        }
        return (true, first.order == .forward)
    }

    private func toggleSortName() {
        if let first = state.tableSortOrder.first, first.keyPath == \WeChatFileItem.name {
            let newOrder: SortOrder = (first.order == .forward) ? .reverse : .forward
            state.tableSortOrder = [KeyPathComparator(\WeChatFileItem.name, order: newOrder)]
        } else {
            state.tableSortOrder = [KeyPathComparator(\WeChatFileItem.name, order: .forward)]
        }
    }

    private func toggleSortSize() {
        if let first = state.tableSortOrder.first, first.keyPath == \WeChatFileItem.size {
            let newOrder: SortOrder = (first.order == .forward) ? .reverse : .forward
            state.tableSortOrder = [KeyPathComparator(\WeChatFileItem.size, order: newOrder)]
        } else {
            state.tableSortOrder = [KeyPathComparator(\WeChatFileItem.size, order: .reverse)]
        }
    }

    private func toggleSortCategory() {
        if let first = state.tableSortOrder.first, first.keyPath == \WeChatFileItem.category.rawValue {
            let newOrder: SortOrder = (first.order == .forward) ? .reverse : .forward
            state.tableSortOrder = [KeyPathComparator(\WeChatFileItem.category.rawValue, order: newOrder)]
        } else {
            state.tableSortOrder = [KeyPathComparator(\WeChatFileItem.category.rawValue, order: .forward)]
        }
    }

    private func toggleSortDate() {
        if let first = state.tableSortOrder.first, first.keyPath == \WeChatFileItem.modificationDate {
            let newOrder: SortOrder = (first.order == .forward) ? .reverse : .forward
            state.tableSortOrder = [KeyPathComparator(\WeChatFileItem.modificationDate, order: newOrder)]
        } else {
            state.tableSortOrder = [KeyPathComparator(\WeChatFileItem.modificationDate, order: .reverse)]
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

            // 解密导出按钮 (当选中项包含 .dat 时提供一键解密为明文图片)
            Button {
                let selected = state.selectedItemIDs.compactMap { state.itemMap[$0] }
                exportDecryptedItems(selected)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.up")
                    Text("解密导出")
                }
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)

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

    // MARK: - 解密并批量导出为明文文件
    private func exportDecryptedItems(_ items: [WeChatFileItem]) {
        let panel = NSOpenPanel()
        panel.title = "选择解密导出目标文件夹"
        panel.prompt = "导出到此目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let targetDir = panel.url else { return }

        Task.detached(priority: .userInitiated) {
            var successCount = 0
            for item in items {
                if item.url.pathExtension.lowercased() == "dat" {
                    if (try? WeChatDatDecoder.shared.exportDecryptedFile(from: item.url, to: targetDir)) != nil {
                        successCount += 1
                    }
                } else {
                    let dest = targetDir.appendingPathComponent(item.name)
                    try? FileManager.default.copyItem(at: item.url, to: dest)
                    successCount += 1
                }
            }

            await MainActor.run {
                state.showAlert = true
                state.alertMessage = "成功解密并导出 \(successCount) 项文件到：\(targetDir.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([targetDir])
            }
        }
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

    // MARK: - 键盘快捷键监听
    private func setupKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if let firstResponder = NSApp.keyWindow?.firstResponder,
               firstResponder is NSTextView || firstResponder is NSTextField {
                return event
            }

            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])

            // 1. ⌘ + A 全选当前列表
            if flags == .command && (event.charactersIgnoringModifiers?.lowercased() == "a" || event.keyCode == 0) {
                state.selectAllFiltered()
                return nil
            }

            // 2. ⌘ + Backspace (或 Delete) 移入废纸篓
            if flags == .command && (event.keyCode == 51 || event.keyCode == 117) {
                if !state.selectedItemIDs.isEmpty {
                    state.cleanSelected(preserveThumbnails: true)
                    return nil
                }
            }

            // 3. 空格键 (QuickLook 预览)
            if event.keyCode == 49 {
                if let url = firstSelectedURL {
                    QuickLookManager.shared.togglePreview(for: url)
                    return nil
                }
            }

            // 4. ESC 键清除选择
            if event.keyCode == 53 {
                if !state.selectedItemIDs.isEmpty {
                    state.clearSelection()
                    return nil
                }
            }

            // 5. 方向键导航 (↑ 上一项, ↓ 下一项, ⌘↑ 首项, ⌘↓ 末项)
            if event.keyCode == 126 { // Up arrow
                if flags.contains(.command) {
                    state.selectFirstItem()
                } else {
                    state.selectPreviousItem()
                }
                return nil
            }
            if event.keyCode == 125 { // Down arrow
                if flags.contains(.command) {
                    state.selectLastItem()
                } else {
                    state.selectNextItem()
                }
                return nil
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

    @ViewBuilder
    private func contextMenu(for item: WeChatFileItem) -> some View {
        Button("快速预览 (空格)") {
            QuickLookManager.shared.togglePreview(for: item.url)
        }
        Button("在 Finder 中显示") {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        }

        if item.url.pathExtension.lowercased() == "dat" {
            Divider()
            Button("解密并另存为明文图片...") {
                exportDecryptedItems([item])
            }
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

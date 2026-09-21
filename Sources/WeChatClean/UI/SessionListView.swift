import SwiftUI

/// 会话存储管理视图（对标微信官方「管理微信聊天数据」与 Pearcleaner 胶囊设计）
public struct SessionListView: View {
    @Bindable var state: AppState

    @State private var searchText: String = ""
    @State private var editingSessionID: String? = nil
    @State private var editingRemarkText: String = ""
    @State private var sortOption: SessionSortOption = .sizeDesc
    @State private var showKeySheet: Bool = false
    @State private var keyMonitor: Any?

    public enum SessionSortOption: String, CaseIterable, Identifiable {
        case sizeDesc = "按占用大小 (从大到小)"
        case dateDesc = "按最后活跃 (从新到旧)"
        case countDesc = "按文件数量 (从多到少)"

        public var id: String { rawValue }
    }

    public init(state: AppState) {
        self.state = state
    }

    private var filteredSessions: [WeChatSessionItem] {
        var list = state.sessions
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            list = list.filter {
                $0.effectiveName.lowercased().contains(query) ||
                $0.id.lowercased().contains(query) ||
                ($0.contact?.nickname.lowercased().contains(query) ?? false) ||
                ($0.contact?.id.lowercased().contains(query) ?? false) ||
                ($0.contact?.remark?.lowercased().contains(query) ?? false)
            }
        }

        switch sortOption {
        case .sizeDesc:
            list.sort { $0.size > $1.size }
        case .dateDesc:
            list.sort { $0.latestDate > $1.latestDate }
        case .countDesc:
            list.sort { $0.fileCount > $1.fileCount }
        }
        return list
    }

    private var totalSessionSize: Int64 {
        state.sessions.reduce(0) { $0 + $1.size }
    }

    private var selectedSessionsTotalSize: Int64 {
        state.sessions.filter { state.selectedSessionIDs.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                // 1. 顶部 Header
                headerView
                    .padding(.horizontal, 22)
                    .padding(.top, 24)
                    .padding(.bottom, 12)

                Divider()
                    .padding(.horizontal, 22)

                // 2. 列表内容
                if state.scanProgress.isScanning && state.sessions.isEmpty {
                    loadingView
                } else if filteredSessions.isEmpty {
                    emptyView
                } else {
                    sessionTable
                }
            }

            // 3. 底部悬浮操作条 (Floating Action Bar, Pearcleaner 胶囊风格)
            if !state.selectedSessionIDs.isEmpty {
                floatingActionBar
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showKeySheet) {
            DatabaseKeySheet(state: state)
        }
        .onAppear {
            setupKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
        }
    }

    // MARK: - 键盘快捷键监听
    private func setupKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if let firstResponder = NSApp.keyWindow?.firstResponder,
               firstResponder is NSTextView || firstResponder is NSTextField {
                return event
            }

            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])

            // 1. ⌘ + A 全选会话
            if flags == .command && (event.charactersIgnoringModifiers?.lowercased() == "a" || event.keyCode == 0) {
                state.selectedSessionIDs = Set(filteredSessions.map { $0.id })
                return nil
            }

            // 2. ⌘ + Delete 清理所选会话
            if flags == .command && (event.keyCode == 51 || event.keyCode == 117) {
                if !state.selectedSessionIDs.isEmpty {
                    state.cleanSelectedSessions()
                    return nil
                }
            }

            // 3. ESC 清除选择
            if event.keyCode == 53 {
                if !state.selectedSessionIDs.isEmpty {
                    state.selectedSessionIDs.removeAll()
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

    // MARK: - 顶部 Header
    private var headerView: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("会话存储分析")
                        .font(.system(size: 20, weight: .bold))

                    Text("管理微信聊天数据")
                        .font(.system(size: 11))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        .foregroundStyle(Color.accentColor)
                }

                Text("共 \(state.sessions.count) 个会话 · \(ByteCountFormatter.string(fromByteCount: totalSessionSize, countStyle: .file)) (支持自定义备注联系人)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // 搜索框
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                TextField("搜索会话备注或哈希...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 140)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
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

            // 排序菜单
            Picker("排序", selection: $sortOption) {
                ForEach(SessionSortOption.allCases) { opt in
                    Text(opt.rawValue).tag(opt)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 160)

            // 数据库密钥设置按钮
            Button {
                showKeySheet = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: WeChatContactManager.shared.hasKey ? "key.fill" : "key")
                        .foregroundStyle(WeChatContactManager.shared.hasKey ? Color.green : Color.secondary)
                    Text("密钥设置")
                }
                .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("配置或导入微信数据库密钥以解密联系人与群聊")
        }
    }

    // MARK: - 表格内容
    private var sessionTable: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(Array(filteredSessions.enumerated()), id: \.element.id) { index, session in
                    sessionRow(session: session, rank: index + 1)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .padding(.bottom, 60) // 避让底部悬浮胶囊
        }
    }

    // MARK: - 单行会话卡片
    private func sessionRow(session: WeChatSessionItem, rank: Int) -> some View {
        let isSelected = state.selectedSessionIDs.contains(session.id)

        return HStack(spacing: 12) {
            // 选择框
            Button {
                if isSelected {
                    state.selectedSessionIDs.remove(session.id)
                } else {
                    state.selectedSessionIDs.insert(session.id)
                }
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
            }
            .buttonStyle(.plain)

            // 排名角标
            Text("\(rank)")
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(rank <= 3 ? Color.accentColor : Color.secondary)
                .frame(width: 24, alignment: .center)

            // 会话头像/图标 (优先展示解密后的首个附件缩略图)
            if let thumbURL = session.firstThumbnailURL {
                MediaThumbnailView(
                    item: WeChatFileItem(
                        url: thumbURL,
                        size: 0,
                        category: .attach,
                        creationDate: .distantPast,
                        modificationDate: .distantPast
                    ),
                    size: 36
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.1))
                        .frame(width: 36, height: 36)

                    Image(systemName: session.contact != nil ? (session.contact!.id.hasSuffix("@chatroom") ? "person.3.fill" : "person.crop.circle.fill") : "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.accentColor)
                }
            }

            // 会话名称与备注
            VStack(alignment: .leading, spacing: 3) {
                if editingSessionID == session.id {
                    HStack(spacing: 6) {
                        TextField("输入联系人/群聊备注", text: $editingRemarkText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .frame(maxWidth: 220)

                        Button("保存") {
                            state.updateSessionRemark(sessionID: session.id, remark: editingRemarkText)
                            editingSessionID = nil
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)

                        Button("取消") {
                            editingSessionID = nil
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                    }
                } else {
                    HStack(spacing: 6) {
                        Text(session.effectiveName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)

                        if let contact = session.contact {
                            Text(contact.id.hasSuffix("@chatroom") ? "群聊" : "好友")
                                .font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                                .foregroundStyle(Color.accentColor)
                        }

                        Button {
                            editingSessionID = session.id
                            editingRemarkText = session.customName ?? ""
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("添加/修改联系人备注")
                    }

                    if let contact = session.contact {
                        Text("\(contact.id) · \(session.fileCount) 项附件 · 最近 \(session.formattedDate)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("ID: \(session.id.prefix(12))... · \(session.fileCount) 项附件 · 最近 \(session.formattedDate)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            // 占用体积
            Text(session.formattedSize)
                .font(.system(size: 13, weight: session.size >= 1024 * 1024 * 1024 ? .bold : .medium).monospacedDigit())
                .foregroundStyle(session.size >= 1024 * 1024 * 1024 ? Color.primary : Color.secondary)

            // 查看附件详情按钮
            Button {
                state.enterSessionDrillDown(session: session)
            } label: {
                HStack(spacing: 3) {
                    Text("查看附件")
                    Image(systemName: "chevron.right")
                }
                .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.06) : Color.primary.opacity(0.02))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.04), lineWidth: 1)
        }
    }

    // MARK: - 悬浮操作条 (Pearcleaner 胶囊风格)
    private var floatingActionBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.tint)
                Text("已选 \(state.selectedSessionIDs.count) 个会话")
                    .font(.system(size: 12, weight: .semibold))
                Text("(\(ByteCountFormatter.string(fromByteCount: selectedSessionsTotalSize, countStyle: .file)))")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Divider().frame(height: 12)

            Button(state.selectedSessionIDs.count == filteredSessions.count ? "取消全选" : "全选所有会话") {
                if state.selectedSessionIDs.count == filteredSessions.count {
                    state.selectedSessionIDs.removeAll()
                } else {
                    state.selectedSessionIDs = Set(filteredSessions.map { $0.id })
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)

            Button(role: .destructive) {
                state.cleanSelectedSessions()
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

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text("正在分析会话存储数据...")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("未发现会话数据")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Text("当前微信目录下暂无附件会话目录。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

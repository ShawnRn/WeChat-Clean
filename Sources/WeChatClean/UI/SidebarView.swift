import SwiftUI

public struct SidebarView: View {
    @Bindable var state: AppState
    @Namespace private var sidebarNamespace
    @State private var hoveredCategory: WeChatCategory?
    @State private var showAccountEditSheet: Bool = false

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 1. Logo Header (预留 54pt 避开红黄绿交通灯，对齐 MotrixMac)
            LogoHeader()
                .padding(.top, 54)
                .padding(.bottom, 20)

            // 2. 账号选择或权限提示
            accountSection
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            // 2.1 密钥提取显性卡片 (未配置时显眼引导，已配置时轻量提示)
            keyStatusSection
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            Divider()
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            // 3. 核心分类胶囊导航 (MotrixMac 风格)
            ScrollView {
                VStack(spacing: 6) {
                    // 会话存储分析专有入口
                    let isSessionSelected = state.isSessionMode
                    let sessionSize = state.categorySize(.attach)
                    let sessionBadge = sessionSize > 0 ? ByteCountFormatter.string(fromByteCount: sessionSize, countStyle: .file) : nil

                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                            state.isSessionMode = true
                            state.drillDownSession = nil
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                                .font(.system(size: 13))
                                .frame(width: 18)
                                .foregroundStyle(isSessionSelected ? Color.accentColor : .secondary)

                            Text("会话存储分析")
                                .font(.system(size: 12, weight: isSessionSelected ? .semibold : .regular))
                                .foregroundStyle(isSessionSelected ? Color.primary : .secondary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)

                            Spacer()

                            if let badge = sessionBadge {
                                Text(badge)
                                    .font(.system(size: 10).monospacedDigit())
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background {
                            if isSessionSelected {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.12))
                                    .matchedGeometryEffect(id: "sidebarSelection", in: sidebarNamespace)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .padding(.vertical, 4)

                    ForEach(WeChatCategory.allCases) { category in
                        let isSelected = !state.isSessionMode && state.selectedCategory == category
                        let isHovered = hoveredCategory == category
                        let size = state.categorySize(category)
                        let badge = size > 0 ? ByteCountFormatter.string(fromByteCount: size, countStyle: .file) : nil

                        SidebarItem(
                            category: category,
                            isSelected: isSelected,
                            isHovered: isHovered,
                            badgeText: badge,
                            namespace: sidebarNamespace
                        ) {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                state.isSessionMode = false
                                state.drillDownSession = nil
                                state.selectedCategory = category
                            }
                        }
                        .onHover { hovering in
                            withAnimation(.easeInOut(duration: 0.15)) {
                                hoveredCategory = hovering ? category : nil
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
            }

            Spacer()

            Divider()
                .padding(.horizontal, 16)

            // 4. 底部状态与刷新
            bottomSection
                .padding(.horizontal, 16)
                .padding(.bottom, 18)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $showAccountEditSheet) {
            AccountEditSheet(state: state, isPresented: $showAccountEditSheet)
        }
    }

    // MARK: - 密钥状态与一键提取卡片
    @ViewBuilder
    private var keyStatusSection: some View {
        let hasKey = WeChatContactManager.shared.hasKey
        let contactCount = WeChatContactManager.shared.loadedContactCount

        if !hasKey {
            Button {
                state.showDatabaseKeySheet = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.orange)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("一键提取联系人与会话密钥")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("自动识别好友昵称与会话")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.orange.opacity(0.12))
                        .stroke(Color.orange.opacity(0.28), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .help("一键提权提取数据库密钥以显示联系人昵称与群名")
        } else {
            Button {
                state.showDatabaseKeySheet = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)

                    Text("已关联 \(contactCount) 位联系人")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    Image(systemName: "key.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                )
            }
            .buttonStyle(.plain)
            .help("数据库密钥已生效，点击可查看或重新配置")
        }
    }

    // MARK: - 账号与权限区域
    @ViewBuilder
    private var accountSection: some View {
        switch state.detectionResult {
        case .success(let accounts):
            if accounts.isEmpty {
                Button {
                    state.promptForWeChatDirectory()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.badge.plus")
                            .foregroundStyle(.tint)
                        Text("手动选择微信目录")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
            } else {
                HStack(spacing: 10) {
                    // 头像
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.12))
                            .frame(width: 34, height: 34)
                        Image(systemName: "person.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.accentColor)
                    }

                    // 昵称与微信号
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.selectedAccount?.displayTitle ?? "微信账号")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)

                        Text(state.selectedAccount?.displaySubtitle ?? "未设置微信号")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    // 编辑资料按钮
                    Button {
                        showAccountEditSheet = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(5)
                            .background(Circle().fill(Color.primary.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                    .help("编辑微信昵称与微信号")

                    // 账号切换菜单
                    if accounts.count > 1 {
                        Menu {
                            ForEach(accounts) { account in
                                Button {
                                    state.selectedAccount = account
                                    state.startScan()
                                } label: {
                                    HStack {
                                        Text(account.displayTitle)
                                        if account.id == state.selectedAccount?.id {
                                            Spacer()
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                            Divider()
                            Button("指定其他微信目录...") {
                                state.promptForWeChatDirectory()
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 14)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            }

        case .permissionDenied:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Text("需要授权访问")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.orange)
                }

                Text("请在系统设置中允许访问文件，或点击手动授权。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Button("授权目录") {
                        state.promptForWeChatDirectory()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)

                    Button("系统设置") {
                        WeChatDetector.openPrivacyPreferences()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.08)))

        case .notFound:
            Button {
                state.promptForWeChatDirectory()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                    Text("定位微信数据")
                        .font(.system(size: 11, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - 底部状态
    @ViewBuilder
    private var bottomSection: some View {
        VStack(spacing: 6) {
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(state.isWeChatRunning ? .green : .gray.opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text(state.isWeChatRunning ? "微信正在运行" : "微信已退出")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    state.refreshAccounts()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("重新扫描")
            }

            if state.scanProgress.isScanning {
                ProgressView(value: Double(state.scanProgress.scannedCount), total: max(Double(state.scanProgress.scannedCount + 200), 500))
                    .progressViewStyle(.linear)
                Text(state.scanProgress.statusMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

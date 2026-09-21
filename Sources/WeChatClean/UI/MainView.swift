import SwiftUI
import QuickLook

public struct MainView: View {
    @State private var state = AppState()
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all

    public init() {}

    public var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            SidebarView(state: state)
                .navigationSplitViewColumnWidth(min: 240, ideal: 250, max: 320)
        } detail: {
            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .quickLookPreview($state.previewURL)
        .sheet(isPresented: $state.showDatabaseKeySheet) {
            DatabaseKeySheet(state: state)
        }
        .alert("提示", isPresented: $state.showAlert) {
            Button("好", role: .cancel) {}
        } message: {
            if let msg = state.alertMessage {
                Text(msg)
            }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        switch state.detectionResult {
        case .permissionDenied:
            permissionDeniedView
        case .notFound:
            if state.accounts.isEmpty {
                notFoundView
            } else {
                categoryContent
            }
        case .success:
            if state.accounts.isEmpty {
                notFoundView
            } else {
                categoryContent
            }
        }
    }

    @ViewBuilder
    private var categoryContent: some View {
        Group {
            if state.isSessionMode {
                SessionListView(state: state)
            } else if state.selectedCategory == .duplicates {
                DuplicateListView(state: state)
            } else {
                FileListView(state: state)
            }
        }
    }

    // MARK: - 权限引导视图 (MotrixMac 风格卡片)
    private var permissionDeniedView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(.orange.opacity(0.12))
                    .frame(width: 80, height: 80)
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
            }

            VStack(spacing: 8) {
                Text("需要授予微信数据访问权限")
                    .font(.system(size: 18, weight: .bold))

                Text("微信 4.x 数据存储在 macOS 沙盒保护目录中。\n请在系统设置中允许本应用访问文件，或点击下方按钮直接授权微信数据目录。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .frame(maxWidth: 420)
            }

            HStack(spacing: 14) {
                Button {
                    state.promptForWeChatDirectory()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.badge.plus")
                        Text("手动选择并授权微信目录")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    WeChatDetector.openPrivacyPreferences()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape")
                        Text("打开系统权限设置")
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 未发现数据视图
    private var notFoundView: some View {
        VStack(spacing: 18) {
            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text("未发现微信 4.x 数据")
                    .font(.system(size: 16, weight: .bold))

                Text("请确保当前 Mac 已登录过微信 4.x，或者手动指定 xwechat_files 目录。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Button {
                state.promptForWeChatDirectory()
            } label: {
                Label("手动选择微信目录", systemImage: "folder")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

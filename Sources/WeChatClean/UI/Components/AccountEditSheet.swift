import SwiftUI

/// 账号资料编辑弹窗（支持自定义微信昵称与微信号，解决微信加密导致的 wxid 乱码展示问题）
public struct AccountEditSheet: View {
    @Bindable var state: AppState
    @Binding var isPresented: Bool

    @State private var nickname: String = ""
    @State private var wechatId: String = ""
    @State private var showKeySheet: Bool = false

    public init(state: AppState, isPresented: Binding<Bool>) {
        self.state = state
        self._isPresented = isPresented
    }

    public var body: some View {
        VStack(spacing: 20) {
            // 头部图标与标题
            VStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor)

                Text("自定义微信账号资料")
                    .font(.system(size: 16, weight: .bold))

                Text("微信 4.x 加密了本地数据库。在此设置后，侧边栏与管理界面将永久展示您的真实微信昵称与微信号。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
            }

            // 表单字段
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("微信昵称")
                        .font(.system(size: 12, weight: .medium))
                    TextField("例如: Shawn Rain", text: $nickname)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("微信号 (WeChat ID)")
                        .font(.system(size: 12, weight: .medium))
                    TextField("例如: srphotographs", text: $wechatId)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }

                if let currentAccount = state.selectedAccount {
                    Text("当前系统账号 ID: \(currentAccount.id)")
                        .font(.system(size: 10).monospaced())
                        .foregroundStyle(.tertiary)
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("联系人数据库密钥")
                            .font(.system(size: 12, weight: .medium))
                        Text(WeChatContactManager.shared.hasKey ? "已配置 (已关联 \(WeChatContactManager.shared.loadedContactCount) 个联系人)" : "未配置 (显示会话哈希)")
                            .font(.system(size: 10))
                            .foregroundStyle(WeChatContactManager.shared.hasKey ? .green : .secondary)
                    }

                    Spacer()

                    Button("设置密钥...") {
                        showKeySheet = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 4)
            .sheet(isPresented: $showKeySheet) {
                DatabaseKeySheet(state: state)
            }

            // 操作按钮
            HStack(spacing: 12) {
                Button("取消") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("保存资料") {
                    state.updateAccountProfile(nickname: nickname, wechatId: wechatId)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear {
            if let acc = state.selectedAccount {
                self.nickname = acc.customNickname ?? ""
                self.wechatId = acc.customWeChatID ?? ""
            }
        }
    }
}

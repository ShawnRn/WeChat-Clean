import SwiftUI
import AppKit

/// 数据库密钥配置弹窗（支持一键导入 all_keys.json 或手动粘贴 64 位 Hex 密钥）
public struct DatabaseKeySheet: View {
    @Bindable var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var hexKeyInput: String = ""
    @State private var statusMessage: String? = nil
    @State private var isError: Bool = false
    @State private var isExtracting: Bool = false

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        VStack(spacing: 20) {
            // 1. 顶部 Header
            HStack(spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text("微信数据库密钥设置")
                        .font(.headline)
                    Text("用于解密 contact.db 以自动显示好友昵称、群名称及头像")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            Divider()

            // 2. 当前状态卡片
            HStack(spacing: 12) {
                let hasKey = WeChatContactManager.shared.hasKey
                let count = WeChatContactManager.shared.loadedContactCount

                Image(systemName: hasKey ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(hasKey ? .green : .orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(hasKey ? "已配置数据库密钥" : "未配置数据库密钥")
                        .font(.system(size: 13, weight: .semibold))
                    Text(hasKey ? "已成功关联 \(count) 个微信联系人及群聊" : "未解密状态下将显示会话哈希（您仍可手动设置备注）")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if hasKey {
                    Button(role: .destructive) {
                        WeChatContactManager.shared.clearKeys()
                        state.reloadContacts()
                        hexKeyInput = ""
                        statusMessage = "已清除密钥配置"
                        isError = false
                    } label: {
                        Text("清除")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))

            // 3. 导入与提取区域
            VStack(alignment: .leading, spacing: 14) {
                // 方式 A: 一键自动提取 (推荐，macOS 标准系统授权)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("方式一：一键自动提取 (推荐)")
                                    .font(.system(size: 12, weight: .bold))
                                Text("免手动")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.accentColor))
                            }
                            Text("调用系统标准提权向您请求管理员权限，自动提取并关联联系人与会话")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            autoExtractKeys()
                        } label: {
                            HStack(spacing: 6) {
                                if isExtracting {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "wand.and.stars")
                                }
                                Text(isExtracting ? "正在提取..." : "自动提取密钥")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isExtracting)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))

                Divider()

                // 方式 B: 文件导入
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("方式二：从文件导入")
                            .font(.system(size: 12, weight: .semibold))
                        Text("支持 wx-cli 或其他工具生成的 all_keys.json 文件")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        chooseAndImportJSON()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text.magnifyingglass")
                            Text("导入 all_keys.json")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Divider()

                // 方式 C: 手动粘贴 Hex 密钥
                VStack(alignment: .leading, spacing: 8) {
                    Text("方式三：手动输入 64 位 Hex 密钥")
                        .font(.system(size: 12, weight: .semibold))

                    HStack(spacing: 8) {
                        TextField("例如: 7f8a9b... (64 位十六进制字符)", text: $hexKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12).monospaced())

                        Button("保存并生效") {
                            applyManualKey()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            // 4. 状态提示文本
            if let msg = statusMessage {
                HStack(spacing: 6) {
                    Image(systemName: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                    Text(msg)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isError ? .red : .green)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 5. 常见问题与说明
            VStack(alignment: .leading, spacing: 6) {
                Text("💡 提取说明与免密方案：")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text("• 微信 4.x 启用了系统加固运行时，读取进程内存需要管理权限。若已有 wx-cli 工具，可在终端运行 `sudo wx init` 提取密钥。\n• 若不便提取密钥，无需担心，您可以随时在会话列表中点击「备注」按钮为会话直接命名，系统将永久记住。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineSpacing(2)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.02)))

            // 6. 底部关闭按钮
            HStack {
                Spacer()
                Button("完成") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.regular)
            }
        }
        .padding(22)
        .frame(width: 480)
        .onAppear {
            if let currentKey = WeChatContactManager.shared.getKey(forDatabase: "contact.db") ?? WeChatContactManager.shared.getKey(forDatabase: "contact") {
                self.hexKeyInput = currentKey
            }
        }
    }

    // MARK: - 导入 all_keys.json
    private func chooseAndImportJSON() {
        let panel = NSOpenPanel()
        panel.title = "选择 all_keys.json 密钥文件"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        let configDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/wx-cli")
        if FileManager.default.fileExists(atPath: configDir.path) {
            panel.directoryURL = configDir
        }

        if panel.runModal() == .OK, let url = panel.url {
            let success = WeChatContactManager.shared.importKeys(from: url)
            if success {
                state.reloadContacts()
                let count = WeChatContactManager.shared.loadedContactCount
                statusMessage = "导入成功！已关联 \(count) 个联系人"
                isError = false
                if let key = WeChatContactManager.shared.getKey(forDatabase: "contact.db") {
                    self.hexKeyInput = key
                }
            } else {
                statusMessage = "导入失败：未能从该 JSON 文件中识别出有效的 64 位密钥"
                isError = true
            }
        }
    }

    // MARK: - 应用手动输入的密钥
    private func applyManualKey() {
        let clean = hexKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count == 64 && clean.allSatisfy({ $0.isHexDigit }) else {
            statusMessage = "密钥格式不正确：必须为 64 位十六进制字符 (32 字节)"
            isError = true
            return
        }

        WeChatContactManager.shared.setKey(clean, forDatabase: "contact.db")
        WeChatContactManager.shared.setKey(clean, forDatabase: "contact")
        state.reloadContacts()

        let count = WeChatContactManager.shared.loadedContactCount
        statusMessage = "密钥已保存！成功加载 \(count) 个联系人"
        isError = false
    }

    // MARK: - 调用系统管理员提权自动提取微信密钥
    private func autoExtractKeys() {
        guard !isExtracting else { return }
        isExtracting = true
        statusMessage = "正在请求系统管理员权限以扫描微信内存..."
        isError = false

        let home = WeChatDetector.realHomeDirectory.path
        let accountID = state.selectedAccount?.id ?? ""
        let dbDir = state.selectedAccount?.url.appendingPathComponent("db_storage").path
            ?? "\(home)/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/\(accountID)/db_storage"
        let targetJson = "\(home)/.config/wx-cli/all_keys.json"

        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default

            // 寻找 extract_keys.py 脚本路径
            var scriptPath: String?
            let possiblePaths = [
                Bundle.main.path(forResource: "extract_keys", ofType: "py"),
                Bundle.main.bundlePath + "/Contents/Resources/scripts/extract_keys.py",
                Bundle.main.bundlePath + "/Contents/Resources/extract_keys.py",
                Bundle.main.bundlePath + "/scripts/extract_keys.py",
                "/Users/shawnrain/Library/Mobile Documents/com~apple~CloudDocs/Shawn Rain/Vibe-Coding/WeChat-Clean/scripts/extract_keys.py"
            ]
            for p in possiblePaths {
                if let p, fm.fileExists(atPath: p) {
                    scriptPath = p
                    break
                }
            }

            guard let validScript = scriptPath else {
                await MainActor.run {
                    self.isExtracting = false
                    self.isError = true
                    self.statusMessage = "未找到密钥提取脚本 extract_keys.py"
                }
                return
            }

            // 寻找 python3 解释器
            let pythonCandidates = ["/opt/homebrew/bin/python3", "/usr/bin/python3", "/usr/local/bin/python3"]
            let pythonBin = pythonCandidates.first { fm.fileExists(atPath: $0) } ?? "python3"

            // 构造带管理员权限的标准 AppleScript
            let cmd = "\"\(pythonBin)\" \"\(validScript)\" \"\(dbDir)\" \"\(targetJson)\""
            let escapedCmd = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let appleScriptSource = "do shell script \"\(escapedCmd)\" with administrator privileges"

            var errorInfo: NSDictionary?
            let appleScript = NSAppleScript(source: appleScriptSource)
            let _ = appleScript?.executeAndReturnError(&errorInfo)

            await MainActor.run {
                self.isExtracting = false
                if let error = errorInfo {
                    let errMsg = (error[NSAppleScript.errorMessage] as? String) ?? "用户取消授权或执行失败"
                    self.isError = true
                    self.statusMessage = "提取失败: \(errMsg)"
                } else {
                    let targetURL = URL(fileURLWithPath: targetJson)
                    let success = WeChatContactManager.shared.importKeys(from: targetURL)
                    if success {
                        self.state.reloadContacts()
                        let count = WeChatContactManager.shared.loadedContactCount
                        self.isError = false
                        self.statusMessage = "提取并关联成功！已成功加载 \(count) 个联系人与好友昵称"
                        if let key = WeChatContactManager.shared.getKey(forDatabase: "contact.db") {
                            self.hexKeyInput = key
                        }
                    } else {
                        self.isError = true
                        self.statusMessage = "提取脚本执行完成，但未能在目标路径识别出密钥"
                    }
                }
            }
        }
    }
}

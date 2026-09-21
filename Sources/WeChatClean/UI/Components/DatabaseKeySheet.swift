import SwiftUI
import AppKit

/// 数据库密钥配置弹窗（支持多账号分别提取及 64 位 Hex 密钥）
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

    private var currentAccountID: String {
        state.selectedAccount?.id ?? ""
    }

    public var body: some View {
        VStack(spacing: 20) {
            // 1. 顶部 Header (展示当前所选账号)
            HStack(spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("微信数据库密钥设置")
                            .font(.headline)

                        if let acc = state.selectedAccount {
                            Text(acc.displayTitle)
                                .font(.system(size: 11, weight: .bold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                                .foregroundStyle(Color.accentColor)
                                .help("账号目录: \(acc.id)")
                        }
                    }

                    Text("针对当前微信账号解密 contact.db，自动识别好友真实昵称、群名称与微信号")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            Divider()

            // 2. 当前状态卡片 (按当前账号隔离展示)
            HStack(spacing: 12) {
                let hasKey = WeChatContactManager.shared.hasKey(for: currentAccountID)
                let count = WeChatContactManager.shared.loadedContactCount
                let myName = state.selectedAccount?.customNickname
                let myAlias = state.selectedAccount?.customWeChatID

                Image(systemName: hasKey ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(hasKey ? .green : .orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(hasKey ? "已配置本账号密钥" : "未配置本账号密钥")
                        .font(.system(size: 13, weight: .semibold))

                    if hasKey {
                        if let myName, !myName.isEmpty {
                            Text("已识别本人：\(myName)\(myAlias != nil ? " (\(myAlias!))" : "") · 关联 \(count) 位联系人与群")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("已成功关联 \(count) 个微信联系人及群聊")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("未解密状态下将显示会话哈希（可在会话列表中手动设置备注）")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if hasKey {
                    Button(role: .destructive) {
                        WeChatContactManager.shared.clearKeys(for: currentAccountID)
                        state.reloadContacts()
                        hexKeyInput = ""
                        statusMessage = "已清除本账号的密钥配置"
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
                // 方式 A: 一键自动提取 (推荐，macOS 原生系统鉴权)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("方式一：一键自动提取 (推荐)")
                                    .font(.system(size: 12, weight: .bold))

                                Text("免手动")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.accentColor))
                            }
                            Text("调用系统标准安全鉴权，全自动提取当前账号的数据库与图片密钥")
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

                // 方式 B: 从文件导入
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

                Text("• 微信 4.x 启用了系统加固运行时，读取进程内存需要管理员权限。点击「自动提取密钥」后在系统弹出的标准鉴权窗口中授权即可自动完成，全部流程在 App 内进行，无需终端操作。\n• 若暂时不便提取密钥，无需担心，您可以随时在会话列表中点击「备注」按钮为会话直接命名，系统将永久记住。")
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
            if let currentKey = WeChatContactManager.shared.getKey(forDatabase: "contact.db", accountID: currentAccountID)
                ?? WeChatContactManager.shared.getKey(forDatabase: "contact", accountID: currentAccountID) {
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
            // 同步解析图片解密密钥
            if let data = try? Data(contentsOf: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let aesStr = json["image_aes_key"] as? String {
                let xorVal = (json["image_xor_key"] as? UInt8) ?? UInt8((json["image_xor_key"] as? Int) ?? 0x88)
                WeChatDatDecoder.shared.setKeyMaterial(aesKeyHex: aesStr, xorKey: xorVal, wxid: currentAccountID)
            }

            let success = WeChatContactManager.shared.importKeys(from: url, forAccount: currentAccountID)
            if success {
                state.reloadContacts()
                let count = WeChatContactManager.shared.loadedContactCount
                let myName = state.selectedAccount?.customNickname ?? ""
                let myAlias = state.selectedAccount?.customWeChatID ?? ""
                let identityStr = !myName.isEmpty ? "「\(myName)」(\(myAlias))" : ""
                statusMessage = "导入成功！已关联 \(identityStr) \(count) 个联系人"
                isError = false
                if let key = WeChatContactManager.shared.getKey(forDatabase: "contact.db", accountID: currentAccountID) {
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

        WeChatContactManager.shared.setKey(clean, forDatabase: "contact.db", accountID: currentAccountID)
        WeChatContactManager.shared.setKey(clean, forDatabase: "contact", accountID: currentAccountID)
        state.reloadContacts()

        let count = WeChatContactManager.shared.loadedContactCount
        let myName = state.selectedAccount?.customNickname ?? ""
        let myAlias = state.selectedAccount?.customWeChatID ?? ""
        let identityStr = !myName.isEmpty ? "账号「\(myName)」(\(myAlias))，" : ""
        statusMessage = "密钥已保存！成功识别 \(identityStr)加载 \(count) 个联系人"
        isError = false
    }

    // MARK: - 调用系统标准安全鉴权自动提取微信密钥 (全流程在 App 内完成，无需打开终端)
    private func autoExtractKeys() {
        guard !isExtracting else { return }
        isExtracting = true
        let accountTitle = state.selectedAccount?.displayTitle ?? "当前账号"
        statusMessage = "正在准备「\(accountTitle)」数据库并请求系统授权..."
        isError = false

        let home = WeChatDetector.realHomeDirectory.path
        let accountID = state.selectedAccount?.id ?? ""
        let dbStorageURL: URL = state.selectedAccount?.url.appendingPathComponent("db_storage")
            ?? URL(fileURLWithPath: "\(home)/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/\(accountID)/db_storage")
        let targetJson = "\(home)/.config/wx-cli/all_keys.json"
        let contactDBURL = dbStorageURL.appendingPathComponent("contact/contact.db")

        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default

            // 1. 优先检查本地已有密钥或 all_keys.json 中是否已有匹配当前账号的有效密钥
            let targetURL = URL(fileURLWithPath: targetJson)
            var cachedMatchedKey: String? = nil

            if let data = try? Data(contentsOf: targetURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                var candidates: [String] = []
                for (k, v) in json {
                    if let s = v as? String, s.count == 64 {
                        candidates.append(s)
                    } else if k == "_candidates", let list = v as? [String] {
                        candidates.append(contentsOf: list)
                    }
                }

                if let aesStr = json["image_aes_key"] as? String {
                    let xorVal = (json["image_xor_key"] as? UInt8) ?? UInt8((json["image_xor_key"] as? Int) ?? 0x88)
                    WeChatDatDecoder.shared.setKeyMaterial(aesKeyHex: aesStr, xorKey: xorVal, wxid: accountID)
                }

                if fm.fileExists(atPath: contactDBURL.path) {
                    for cand in candidates {
                        if let candData = Data(hexString: cand), SQLCipherDecryptor.validateKey(candData, forDatabase: contactDBURL) {
                            cachedMatchedKey = cand
                            break
                        }
                    }
                }
            }

            // 如果本地缓存的密钥完全有效，直接秒级应用，无需弹出系统鉴权
            if let validKey = cachedMatchedKey {
                await MainActor.run {
                    let keysMap: [String: String] = [
                        "contact.db": validKey,
                        "contact": validKey,
                        "contact/contact.db": validKey
                    ]
                    WeChatContactManager.shared.setKeys(keysMap, forAccount: accountID)
                    self.state.reloadContacts()
                    let count = WeChatContactManager.shared.loadedContactCount
                    let myName = self.state.selectedAccount?.customNickname ?? ""
                    let myAlias = self.state.selectedAccount?.customWeChatID ?? ""

                    self.isExtracting = false
                    self.isError = false
                    self.hexKeyInput = validKey

                    if !myName.isEmpty {
                        self.statusMessage = "验证成功！已识别本人「\(myName)」(\(myAlias))，关联 \(count) 位联系人"
                    } else if count > 0 {
                        self.statusMessage = "验证成功！已成功关联 \(count) 位微信联系人及群聊"
                    } else {
                        self.statusMessage = "密钥验证通过并已生效"
                    }
                }
                return
            }

            // 2. 本地无有效密钥：在当前用户权限下读取 db_storage 中各 .db 的前 4096 字节与 Salt
            var dbsInfo: [[String: String]] = []
            if let enumerator = fm.enumerator(at: dbStorageURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                while let fileURL = enumerator.nextObject() as? URL {
                    if fileURL.pathExtension == "db" && !fileURL.lastPathComponent.contains("-wal") && !fileURL.lastPathComponent.contains("-shm") {
                        if let handle = try? FileHandle(forReadingFrom: fileURL) {
                            if let page = try? handle.read(upToCount: 4096), page.count == 4096,
                               page.prefix(16) != Data("SQLite format 3\0".utf8) {
                                let relPath = fileURL.path.replacingOccurrences(of: dbStorageURL.path + "/", with: "")
                                let saltHex = page.prefix(16).map { String(format: "%02x", $0) }.joined()
                                let pageHex = page.map { String(format: "%02x", $0) }.joined()
                                dbsInfo.append([
                                    "name": fileURL.lastPathComponent,
                                    "rel": relPath,
                                    "salt_hex": saltHex,
                                    "page_hex": pageHex
                                ])
                            }
                            try? handle.close()
                        }
                    }
                }
            }

            guard !dbsInfo.isEmpty else {
                await MainActor.run {
                    self.isExtracting = false
                    self.isError = true
                    self.statusMessage = "未在 \(dbStorageURL.path) 下发现加密数据库，请确认微信已登录"
                }
                return
            }

            let tempDbInfoPath = "/tmp/wechat_db_info.json"
            let tempOutputPath = "/tmp/wechat_extracted_keys.json"
            let tempScriptPath = "/tmp/wechat_extract_keys.py"

            let infoData = (try? JSONSerialization.data(withJSONObject: ["dbs": dbsInfo], options: [.prettyPrinted])) ?? Data()
            try? infoData.write(to: URL(fileURLWithPath: tempDbInfoPath))

            // 3. 定位 extract_keys.py 脚本路径并复制到 /tmp (赋予执行权限)
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

            if fm.fileExists(atPath: tempScriptPath) {
                try? fm.removeItem(atPath: tempScriptPath)
            }
            try? fm.copyItem(atPath: validScript, toPath: tempScriptPath)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempScriptPath)

            // 4. 定位 python3 解释器
            let pythonCandidates = ["/opt/homebrew/bin/python3", "/usr/bin/python3", "/usr/local/bin/python3"]
            let pythonBin = pythonCandidates.first { fm.fileExists(atPath: $0) } ?? "python3"

            // 5. 调用系统原生标准安全授权弹窗（完全在 App 内通过 osascript 呼出系统提权对话框）
            let shellCmd = "\"\(pythonBin)\" \"\(tempScriptPath)\" \"\(tempDbInfoPath)\" \"\(tempOutputPath)\""
            let escapedCmd = shellCmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let appleScriptText = "do shell script \"\(escapedCmd)\" with administrator privileges"

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", appleScriptText]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            proc.standardOutput = stdoutPipe
            proc.standardError = stderrPipe

            var runError: String?
            do {
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus != 0 {
                    let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let errStr = (String(data: errData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if errStr.contains("User canceled") || errStr.contains("-128") {
                        runError = "用户取消了系统授权"
                    } else if !errStr.isEmpty {
                        runError = errStr
                    } else {
                        runError = "系统授权执行未完成 (代码: \(proc.terminationStatus))"
                    }
                }
            } catch {
                runError = error.localizedDescription
            }

            // 6. 解析提取结果
            let tempOutputURL = URL(fileURLWithPath: tempOutputPath)
            var extractedKeys: [String: String] = [:]
            var candidates: [String] = []

            if let outData = try? Data(contentsOf: tempOutputURL),
               let json = try? JSONSerialization.jsonObject(with: outData) as? [String: Any] {
                for (k, v) in json {
                    if k == "_candidates", let candList = v as? [String] {
                        candidates = candList
                    } else if let keyStr = v as? String, keyStr.count == 64 {
                        extractedKeys[k] = keyStr
                    }
                }
                if let aesStr = json["image_aes_key"] as? String {
                    let xorVal = (json["image_xor_key"] as? UInt8) ?? UInt8((json["image_xor_key"] as? Int) ?? 0x88)
                    WeChatDatDecoder.shared.setKeyMaterial(aesKeyHex: aesStr, xorKey: xorVal, wxid: accountID)
                }
            }

            // 若 contact.db 没直接匹配上，使用 candidates 对 contact.db 进行二次确权
            if extractedKeys["contact.db"] == nil && fm.fileExists(atPath: contactDBURL.path) {
                for cand in candidates {
                    if let candData = Data(hexString: cand) {
                        if SQLCipherDecryptor.validateKey(candData, forDatabase: contactDBURL) {
                            extractedKeys["contact.db"] = cand
                            extractedKeys["contact/contact.db"] = cand
                            extractedKeys["contact"] = cand
                            break
                        }
                    }
                }
            }

            // 清理临时文件
            try? fm.removeItem(atPath: tempDbInfoPath)
            try? fm.removeItem(atPath: tempOutputPath)
            try? fm.removeItem(atPath: tempScriptPath)

            await MainActor.run {
                self.isExtracting = false
                if let err = runError, extractedKeys.isEmpty {
                    self.isError = true
                    self.statusMessage = "提取未成功: \(err)"
                } else if !extractedKeys.isEmpty {
                    // 绑定当前账号保存专属密钥
                    WeChatContactManager.shared.setKeys(extractedKeys, forAccount: accountID)

                    // 写入持久化备份
                    try? fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if let jsonData = try? JSONSerialization.data(withJSONObject: extractedKeys, options: [.prettyPrinted]) {
                        try? jsonData.write(to: targetURL)
                    }

                    self.state.reloadContacts()
                    let count = WeChatContactManager.shared.loadedContactCount
                    let myName = self.state.selectedAccount?.customNickname ?? ""
                    let myAlias = self.state.selectedAccount?.customWeChatID ?? ""

                    self.isError = false
                    if !myName.isEmpty {
                        self.statusMessage = "提取成功！已成功识别本人「\(myName)」(微信号: \(myAlias))，关联 \(count) 位联系人"
                    } else if count > 0 {
                        self.statusMessage = "提取成功！已成功关联 \(count) 位微信好友与群聊"
                    } else {
                        self.statusMessage = "密钥提取成功并已保存！"
                    }

                    if let key = WeChatContactManager.shared.getKey(forDatabase: "contact.db", accountID: accountID) {
                        self.hexKeyInput = key
                    }
                } else {
                    self.isError = true
                    self.statusMessage = "未在内存中匹配到「\(self.state.selectedAccount?.displayTitle ?? "当前账号")」的有效密钥，请确保微信正在登录该账号"
                }
            }
        }
    }
}

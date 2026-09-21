import Foundation
import AppKit

public enum DetectionResult: Sendable {
    case success([WeChatAccount])
    case permissionDenied(URL)
    case notFound(URL)
}

public struct WeChatDetector: Sendable {
    /// 获取用户真实的主目录（即使在沙盒环境中也能获得真实 /Users/xxx）
    public static var realHomeDirectory: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir))
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// 默认的微信 4.x 数据根目录
    public static var defaultRootURL: URL {
        realHomeDirectory.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files")
    }

    /// 检测本机微信账号并详细报告权限与状态
    public static func detect(at root: URL? = nil) -> DetectionResult {
        let targetRoot = root ?? defaultRootURL
        let fm = FileManager.default

        // 检查路径是否存在
        guard fm.fileExists(atPath: targetRoot.path) else {
            return .notFound(targetRoot)
        }

        // 尝试列出目录内容
        do {
            let contents = try fm.contentsOfDirectory(
                at: targetRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            var accounts: [WeChatAccount] = []
            for folder in contents {
                let name = folder.lastPathComponent
                if name == "Backup" || name == "all_users" || name.hasPrefix(".") {
                    continue
                }

                let msgPath = folder.appendingPathComponent("msg").path
                let configPath = folder.appendingPathComponent("config").path
                let dbPath = folder.appendingPathComponent("db_storage").path

                if fm.fileExists(atPath: msgPath) || fm.fileExists(atPath: configPath) || fm.fileExists(atPath: dbPath) {
                    let displayName = name.hasPrefix("wxid_") ? String(name.dropFirst(5)) : name
                    let profile = loadAccountProfile(for: name)
                    accounts.append(WeChatAccount(
                        id: name,
                        url: folder,
                        displayName: displayName,
                        customNickname: profile.nickname,
                        customWeChatID: profile.wechatId
                    ))
                }
            }

            if accounts.isEmpty {
                // 即使没有找到标准的 wxid 目录，如果该目录下有文件夹，也作为一个候选账号
                for folder in contents where folder.hasDirectoryPath {
                    let name = folder.lastPathComponent
                    let profile = loadAccountProfile(for: name)
                    accounts.append(WeChatAccount(
                        id: name,
                        url: folder,
                        displayName: name,
                        customNickname: profile.nickname,
                        customWeChatID: profile.wechatId
                    ))
                }
            }

            return .success(accounts.sorted { $0.displayTitle < $1.displayTitle })
        } catch {
            let nsError = error as NSError
            // 权限拒绝 (Code 257 或 EPERM)
            if nsError.code == 257 || nsError.domain == NSCocoaErrorDomain {
                return .permissionDenied(targetRoot)
            }
            return .permissionDenied(targetRoot)
        }
    }

    // MARK: - 账号与会话本地持久化配置 (UserDefaults)

    private static let profileKeyPrefix = "wechat_clean_profile_"
    private static let sessionRemarksKeyPrefix = "wechat_clean_session_remarks_"

    /// 读取账号自定义资料（昵称与微信号）
    public static func loadAccountProfile(for accountID: String) -> (nickname: String?, wechatId: String?) {
        let key = profileKeyPrefix + accountID
        guard let dict = UserDefaults.standard.dictionary(forKey: key) else {
            return (nil, nil)
        }
        return (dict["nickname"] as? String, dict["wechatId"] as? String)
    }

    /// 保存账号自定义资料
    public static func saveAccountProfile(for accountID: String, nickname: String?, wechatId: String?) {
        let key = profileKeyPrefix + accountID
        var dict: [String: String] = [:]
        if let nick = nickname, !nick.trimmingCharacters(in: .whitespaces).isEmpty {
            dict["nickname"] = nick
        }
        if let wid = wechatId, !wid.trimmingCharacters(in: .whitespaces).isEmpty {
            dict["wechatId"] = wid
        }
        UserDefaults.standard.set(dict, forKey: key)
    }

    /// 读取会话联系人备注列表
    public static func loadSessionRemarks(for accountID: String) -> [String: String] {
        let key = sessionRemarksKeyPrefix + accountID
        return (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
    }

    /// 保存单个会话联系人备注
    public static func saveSessionRemark(for accountID: String, sessionID: String, remark: String) {
        let key = sessionRemarksKeyPrefix + accountID
        var dict = loadSessionRemarks(for: accountID)
        let trimmed = remark.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            dict.removeValue(forKey: sessionID)
        } else {
            dict[sessionID] = trimmed
        }
        UserDefaults.standard.set(dict, forKey: key)
    }

    /// 兼容接口：返回账号列表
    public static func detectAccounts(at root: URL? = nil) -> [WeChatAccount] {
        switch detect(at: root) {
        case .success(let accounts): return accounts
        default: return []
        }
    }

    /// 唤起系统 NSOpenPanel 允许用户手动选择并授权微信数据目录
    @MainActor
    public static func chooseWeChatDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择微信数据目录 (xwechat_files)"
        panel.prompt = "授权访问"
        panel.message = "请选择微信 4.x 数据目录 (通常位于 Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files)"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = defaultRootURL

        if panel.runModal() == .OK {
            return panel.url
        }
        return nil
    }

    /// 检查微信是否正在运行
    public static func isWeChatRunning() -> Bool {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.xinWeChat")
        return !apps.isEmpty
    }

    /// 打开系统设置的“完全磁盘访问权限”面板
    @MainActor
    public static func openPrivacyPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

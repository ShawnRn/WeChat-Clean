import Foundation
import CryptoKit
import SQLite3

/// 微信联系人信息模型
public struct WeChatContact: Identifiable, Sendable, Codable, Hashable {
    public let id: String // wxid 或微信号/群ID (m_nsUsrName)
    public let nickname: String // 昵称 (m_nsNickName)
    public let remark: String? // 备注名 (m_nsRemark)
    public let avatarURL: String? // 头像地址 (m_nsHeadImgUrl)
    public let chatMD5: String // md5(id)，对应 msg/attach/<md5> 目录名

    public var displayName: String {
        if let remark, !remark.trimmingCharacters(in: .whitespaces).isEmpty {
            return remark
        }
        if !nickname.trimmingCharacters(in: .whitespaces).isEmpty {
            return nickname
        }
        return id
    }

    public init(id: String, nickname: String, remark: String?, avatarURL: String?, chatMD5: String? = nil) {
        self.id = id
        self.nickname = nickname
        self.remark = remark
        self.avatarURL = avatarURL
        if let chatMD5 {
            self.chatMD5 = chatMD5
        } else {
            let digest = Insecure.MD5.hash(data: Data(id.utf8))
            self.chatMD5 = digest.map { String(format: "%02x", $0) }.joined()
        }
    }
}

/// 微信联系人管理器（负责联系人数据加载、双向散列索引与会话映射）
public final class WeChatContactManager: @unchecked Sendable {
    public static let shared = WeChatContactManager()

    private let lock = NSLock()
    private var contactsByMD5: [String: WeChatContact] = [:]
    private var contactsByID: [String: WeChatContact] = [:]
    private var dbKeys: [String: String] = [:] // dbName -> 64-hex key

    private init() {
        loadCachedKeys()
    }

    /// 读取已缓存的数据库密钥
    private func loadCachedKeys() {
        lock.lock()
        defer { lock.unlock() }

        if let saved = UserDefaults.standard.dictionary(forKey: "wechat_db_keys") as? [String: String] {
            dbKeys.merge(saved) { (_, new) in new }
        }

        // 尝试从 ~/.config/wx-cli/all_keys.json 读取
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidatePaths = [
            "\(home)/.config/wx-cli/all_keys.json",
            "\(home)/Library/Application Support/WeChatClean/all_keys.json"
        ]

        for path in candidatePaths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            for (k, v) in json {
                if let keyStr = v as? String, keyStr.count == 64 {
                    dbKeys[k] = keyStr
                } else if let dict = v as? [String: Any], let keyStr = dict["key"] as? String, keyStr.count == 64 {
                    dbKeys[k] = keyStr
                }
            }
        }
    }

    /// 是否已配置数据库密钥
    public var hasKey: Bool {
        lock.lock()
        defer { lock.unlock() }
        return dbKeys["contact.db"] != nil || dbKeys["contact"] != nil
    }

    /// 当前已加载的联系人总数
    public var loadedContactCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return contactsByID.count
    }

    /// 从 JSON 文件（如 all_keys.json）中导入密钥
    public func importKeys(from fileURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        var found = false
        lock.lock()
        for (k, v) in json {
            if let keyStr = v as? String, keyStr.count == 64 {
                dbKeys[k] = keyStr
                found = true
            } else if let dict = v as? [String: Any], let keyStr = dict["key"] as? String, keyStr.count == 64 {
                dbKeys[k] = keyStr
                found = true
            }
        }
        if found {
            UserDefaults.standard.set(dbKeys, forKey: "wechat_db_keys")
        }
        lock.unlock()
        return found
    }

    /// 清除已配置的密钥与联系人缓存
    public func clearKeys() {
        lock.lock()
        dbKeys.removeAll()
        contactsByMD5.removeAll()
        contactsByID.removeAll()
        UserDefaults.standard.removeObject(forKey: "wechat_db_keys")
        lock.unlock()
    }

    /// 保存单个数据库密钥
    public func setKey(_ hexKey: String, forDatabase dbName: String) {
        lock.lock()
        let clean = hexKey.trimmingCharacters(in: .whitespacesAndNewlines)
        dbKeys[dbName] = clean
        UserDefaults.standard.set(dbKeys, forKey: "wechat_db_keys")
        lock.unlock()
    }

    /// 获取特定数据库密钥
    public func getKey(forDatabase dbName: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return dbKeys[dbName]
    }

    /// 针对指定账号加载联系人并返回加载成功的联系人数量
    @discardableResult
    public func loadContacts(for account: WeChatAccount) -> Int {
        let contactDBURL = account.url.appendingPathComponent("db_storage/contact/contact.db")
        guard FileManager.default.fileExists(atPath: contactDBURL.path) else { return 0 }

        // 获取 contact.db 密钥
        guard let keyHex = getKey(forDatabase: "contact.db") ?? getKey(forDatabase: "contact"),
              let keyData = hexToData(keyHex), keyData.count == 32 else {
            return 0
        }

        let tempDB = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wechat_clean_contact_\(account.id).db")

        do {
            try SQLCipherDecryptor.decryptDatabase(at: contactDBURL, to: tempDB, key: keyData)
            let loaded = try readContactsFromDecryptedDB(tempDB)
            lock.lock()
            for c in loaded {
                contactsByMD5[c.chatMD5] = c
                contactsByID[c.id] = c
            }
            let total = contactsByID.count
            lock.unlock()

            // 自动检测是否包含当前用户自身，如果有则更新当前账号的显示昵称
            let normalizedAccountID: String
            if account.id.hasPrefix("wxid_") {
                let stripped = String(account.id.dropFirst(5))
                normalizedAccountID = "wxid_" + (stripped.components(separatedBy: "_").first ?? stripped)
            } else {
                normalizedAccountID = account.id
            }

            if let me = loaded.first(where: { $0.id == account.id || $0.id == normalizedAccountID }) {
                WeChatDetector.saveAccountProfile(for: account.id, nickname: me.nickname, wechatId: me.id)
            }

            return total
        } catch {
            print("Failed to decrypt or load contact.db: \(error)")
            return 0
        }
    }

    /// 从已解密的 SQLite contact.db 中读取联系人（同时兼容 4.x contact 与 3.x Contact 表）
    private func readContactsFromDecryptedDB(_ dbURL: URL) throws -> [WeChatContact] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw NSError(domain: "WeChatContactManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法打开 SQLite 数据库"])
        }
        defer { sqlite3_close(db) }

        var contacts: [WeChatContact] = []

        // 1. 微信 4.x 结构：表名为 contact，字段为 username, nick_name, remark, verify_flag
        let queryV4 = "SELECT username, nick_name, remark FROM contact WHERE username IS NOT NULL AND username != '';"
        var stmtV4: OpaquePointer?
        if sqlite3_prepare_v2(db, queryV4, -1, &stmtV4, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmtV4) }
            while sqlite3_step(stmtV4) == SQLITE_ROW {
                let usrName = sqlite3_column_text(stmtV4, 0).map { String(cString: $0) } ?? ""
                let nickName = sqlite3_column_text(stmtV4, 1).map { String(cString: $0) } ?? ""
                let remark = sqlite3_column_text(stmtV4, 2).map { String(cString: $0) }
                guard !usrName.isEmpty else { continue }
                contacts.append(WeChatContact(id: usrName, nickname: nickName, remark: remark, avatarURL: nil))
            }
            if !contacts.isEmpty {
                return contacts
            }
        }

        // 2. 微信 3.x 结构：表名为 Contact，字段为 m_nsUsrName, m_nsNickName, m_nsRemark, m_nsHeadImgUrl
        let queryV3 = "SELECT m_nsUsrName, m_nsNickName, m_nsRemark, m_nsHeadImgUrl FROM Contact WHERE m_nsUsrName IS NOT NULL AND m_nsUsrName != '';"
        var stmtV3: OpaquePointer?
        if sqlite3_prepare_v2(db, queryV3, -1, &stmtV3, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmtV3) }
            while sqlite3_step(stmtV3) == SQLITE_ROW {
                let usrName = sqlite3_column_text(stmtV3, 0).map { String(cString: $0) } ?? ""
                let nickName = sqlite3_column_text(stmtV3, 1).map { String(cString: $0) } ?? ""
                let remark = sqlite3_column_text(stmtV3, 2).map { String(cString: $0) }
                let headImg = sqlite3_column_text(stmtV3, 3).map { String(cString: $0) }
                guard !usrName.isEmpty else { continue }
                contacts.append(WeChatContact(id: usrName, nickname: nickName, remark: remark, avatarURL: headImg))
            }
        }

        return contacts
    }

    /// 根据 msg/attach 下的 32 位 MD5 目录名匹配真实联系人
    public func contact(forChatMD5 md5: String) -> WeChatContact? {
        lock.lock()
        defer { lock.unlock() }
        return contactsByMD5[md5.lowercased()]
    }

    /// 根据 wxid 查找联系人
    public func contact(forID id: String) -> WeChatContact? {
        lock.lock()
        defer { lock.unlock() }
        return contactsByID[id]
    }

    /// 获取全部联系人列表
    public func allContacts() -> [WeChatContact] {
        lock.lock()
        defer { lock.unlock() }
        return Array(contactsByID.values).sorted { $0.displayName < $1.displayName }
    }

    private func hexToData(_ hex: String) -> Data? {
        let cleanHex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanHex.count % 2 == 0 else { return nil }
        var data = Data(capacity: cleanHex.count / 2)
        var index = cleanHex.startIndex
        while index < cleanHex.endIndex {
            let nextIndex = cleanHex.index(index, offsetBy: 2)
            guard let b = UInt8(cleanHex[index..<nextIndex], radix: 16) else { return nil }
            data.append(b)
            index = nextIndex
        }
        return data
    }
}

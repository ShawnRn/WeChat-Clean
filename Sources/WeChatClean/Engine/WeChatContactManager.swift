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

/// 微信联系人管理器（负责联系人数据加载、双向散列索引、多账号隔离与本人明文资料提取）
public final class WeChatContactManager: @unchecked Sendable {
    public static let shared = WeChatContactManager()

    public struct LoadResult: Sendable {
        public let count: Int
        public let myNickname: String?
        public let myWeChatID: String?
        public let errorMessage: String?
    }

    private let lock = NSLock()
    private var contactsByMD5: [String: WeChatContact] = [:]
    private var contactsByID: [String: WeChatContact] = [:]
    // 按账号隔离存储密钥: accountID -> (dbName -> 64-hex key)
    private var keysByAccount: [String: [String: String]] = [:]
    private var globalKeys: [String: String] = [:]
    private var activeAccountID: String?

    private init() {
        loadCachedKeys()
    }

    /// 读取已缓存的数据库密钥（按账号隔离加载，并兼容全局历史配置）
    private func loadCachedKeys() {
        lock.lock()
        defer { lock.unlock() }

        // 1. 读取全局历史配置
        if let saved = UserDefaults.standard.dictionary(forKey: "wechat_db_keys") as? [String: String] {
            globalKeys = saved
        }

        // 2. 尝试从 ~/.config/wx-cli/all_keys.json 读取通用 fallback
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
                    globalKeys[k] = keyStr
                } else if let dict = v as? [String: Any], let keyStr = dict["key"] as? String, keyStr.count == 64 {
                    globalKeys[k] = keyStr
                }
            }
        }
    }

    /// 切换当前活跃账号，自动载入该账号专属密钥并重载联系人缓存
    public func switchAccount(to account: WeChatAccount) {
        lock.lock()
        activeAccountID = account.id
        contactsByMD5.removeAll()
        contactsByID.removeAll()

        // 载入该账号的专属配置
        let accKey = "wechat_db_keys_\(account.id)"
        if let saved = UserDefaults.standard.dictionary(forKey: accKey) as? [String: String] {
            keysByAccount[account.id] = saved
        }
        lock.unlock()

        // 异步或同步执行一次该账号的联系人加载
        loadContacts(for: account)
    }

    /// 是否已为指定账号配置数据库密钥
    public func hasKey(for accountID: String? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let target = accountID ?? activeAccountID
        if let target, let accMap = keysByAccount[target], !accMap.isEmpty {
            return accMap["contact.db"] != nil || accMap["contact"] != nil
        }
        return globalKeys["contact.db"] != nil || globalKeys["contact"] != nil
    }

    /// 当前活跃账号是否已配置数据库密钥
    public var hasKey: Bool {
        hasKey(for: nil)
    }

    /// 当前已加载的联系人总数
    public var loadedContactCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return contactsByID.count
    }

    /// 获取特定数据库密钥（优先取当前账号专属，次选全局）
    public func getKey(forDatabase dbName: String, accountID: String? = nil) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let target = accountID ?? activeAccountID
        if let target, let map = keysByAccount[target], let key = map[dbName] {
            return key
        }
        return globalKeys[dbName]
    }

    /// 保存单个数据库密钥（区分账号隔离）
    public func setKey(_ hexKey: String, forDatabase dbName: String, accountID: String? = nil) {
        lock.lock()
        let clean = hexKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = accountID ?? activeAccountID

        if let target {
            var map = keysByAccount[target] ?? [:]
            map[dbName] = clean
            keysByAccount[target] = map
            UserDefaults.standard.set(map, forKey: "wechat_db_keys_\(target)")
        } else {
            globalKeys[dbName] = clean
            UserDefaults.standard.set(globalKeys, forKey: "wechat_db_keys")
        }
        lock.unlock()
    }

    /// 批量保存某账号提取的所有密钥
    public func setKeys(_ keys: [String: String], forAccount accountID: String) {
        lock.lock()
        var map = keysByAccount[accountID] ?? [:]
        map.merge(keys) { (_, new) in new }
        keysByAccount[accountID] = map
        UserDefaults.standard.set(map, forKey: "wechat_db_keys_\(accountID)")
        // 同时作为 fallback 写入全局
        globalKeys.merge(keys) { (_, new) in new }
        UserDefaults.standard.set(globalKeys, forKey: "wechat_db_keys")
        lock.unlock()
    }

    /// 清除指定账号（或全局）已配置的密钥与联系人缓存
    public func clearKeys(for accountID: String? = nil) {
        lock.lock()
        let target = accountID ?? activeAccountID
        if let target {
            keysByAccount.removeValue(forKey: target)
            UserDefaults.standard.removeObject(forKey: "wechat_db_keys_\(target)")
        } else {
            globalKeys.removeAll()
            UserDefaults.standard.removeObject(forKey: "wechat_db_keys")
        }
        contactsByMD5.removeAll()
        contactsByID.removeAll()
        lock.unlock()
    }

    /// 从 JSON 文件导入密钥（绑定至当前账号）
    public func importKeys(from fileURL: URL, forAccount accountID: String? = nil) -> Bool {
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        var imported: [String: String] = [:]
        for (k, v) in json {
            if let keyStr = v as? String, keyStr.count == 64 {
                imported[k] = keyStr
            } else if let dict = v as? [String: Any], let keyStr = dict["key"] as? String, keyStr.count == 64 {
                imported[k] = keyStr
            }
        }
        guard !imported.isEmpty else { return false }

        let target = accountID ?? activeAccountID ?? "default"
        setKeys(imported, forAccount: target)
        return true
    }

    /// 针对指定账号加载联系人并自动提取本人真实昵称与微信号
    @discardableResult
    public func loadContacts(for account: WeChatAccount) -> LoadResult {
        let contactDBURL = account.url.appendingPathComponent("db_storage/contact/contact.db")
        guard FileManager.default.fileExists(atPath: contactDBURL.path) else {
            return LoadResult(count: 0, myNickname: nil, myWeChatID: nil, errorMessage: "未找到联系人数据库: \(contactDBURL.path)")
        }

        // 1. 获取该账号专属 contact.db 密钥
        guard let keyHex = getKey(forDatabase: "contact.db", accountID: account.id)
                ?? getKey(forDatabase: "contact/contact.db", accountID: account.id)
                ?? getKey(forDatabase: "contact", accountID: account.id)
                ?? getKey(forDatabase: "contact.db")
                ?? getKey(forDatabase: "contact"),
              let keyData = hexToData(keyHex), keyData.count == 32 else {
            return LoadResult(count: 0, myNickname: nil, myWeChatID: nil, errorMessage: "未配置该账号的 64 位 contact.db 密钥")
        }

        let tempDB = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wechat_clean_contact_\(account.id).db")

        do {
            try SQLCipherDecryptor.decryptDatabase(at: contactDBURL, to: tempDB, key: keyData)
            let (loaded, myProfile) = try readContactsAndProfileFromDecryptedDB(tempDB, accountID: account.id)

            lock.lock()
            activeAccountID = account.id
            for c in loaded {
                contactsByMD5[c.chatMD5] = c
                contactsByID[c.id] = c
            }
            let total = contactsByID.count
            lock.unlock()

            // 2. 如果识别出本人明文资料，立即持久化保存并写入账号资料库
            if let nick = myProfile.nickname ?? myProfile.alias, !nick.isEmpty {
                WeChatDetector.saveAccountProfile(for: account.id, nickname: myProfile.nickname, wechatId: myProfile.alias)
            }

            return LoadResult(count: total, myNickname: myProfile.nickname, myWeChatID: myProfile.alias, errorMessage: nil)
        } catch {
            return LoadResult(count: 0, myNickname: nil, myWeChatID: nil, errorMessage: "解密或读取 contact.db 失败: \(error.localizedDescription)")
        }
    }

    /// 动态自适应扫描 SQLite contact.db：遍历所有表并自省列结构，提取联系人及本人信息
    private func readContactsAndProfileFromDecryptedDB(_ dbURL: URL, accountID: String) throws -> ([WeChatContact], (nickname: String?, alias: String?)) {
        var db: OpaquePointer?
        // 使用标准读写模式打开临时解密数据库，避免 WAL 共享内存创建失败 (SQLITE_CANTOPEN 14)
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            throw NSError(domain: "WeChatContactManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法打开 SQLite 数据库"])
        }
        defer { sqlite3_close(db) }

        // 关闭 journal 以加速读取并释放文件锁
        sqlite3_exec(db, "PRAGMA journal_mode = OFF;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous = OFF;", nil, nil, nil)

        // 1. 获取所有表名
        var tables: [String] = []
        var stmtTables: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table';", -1, &stmtTables, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmtTables) }
            while sqlite3_step(stmtTables) == SQLITE_ROW {
                if let name = sqlite3_column_text(stmtTables, 0).map({ String(cString: $0) }) {
                    let lower = name.lowercased()
                    if lower.contains("contact") && !lower.contains("_fts") && !lower.contains("head_image") {
                        tables.append(name)
                    }
                }
            }
        }

        if tables.isEmpty {
            tables = ["contact", "Contact"]
        }

        var contacts: [WeChatContact] = []
        var detectedMyNickname: String?
        var detectedMyAlias: String?

        let normalizedAccountID: String
        let baseAccountID: String
        if accountID.hasPrefix("wxid_") {
            let stripped = String(accountID.dropFirst(5))
            let pure = stripped.components(separatedBy: "_").first ?? stripped
            normalizedAccountID = "wxid_" + pure
            baseAccountID = pure
        } else {
            normalizedAccountID = accountID
            baseAccountID = accountID
        }

        for table in tables {
            // 2. 自省列结构
            var columnNames: [String] = []
            var stmtCols: OpaquePointer?
            if sqlite3_prepare_v2(db, "PRAGMA table_info(\"\(table)\");", -1, &stmtCols, nil) == SQLITE_OK {
                while sqlite3_step(stmtCols) == SQLITE_ROW {
                    if let colName = sqlite3_column_text(stmtCols, 1).map({ String(cString: $0) }) {
                        columnNames.append(colName)
                    }
                }
                sqlite3_finalize(stmtCols)
            }

            // 识别列
            let idCol = columnNames.first(where: { ["username", "m_nsusrname", "usrname", "wxid"].contains($0.lowercased()) })
            let nickCol = columnNames.first(where: { ["nick_name", "m_nsnickname", "nickname"].contains($0.lowercased()) })
            let remarkCol = columnNames.first(where: { ["remark", "m_nsremark", "conremark"].contains($0.lowercased()) })
            let aliasCol = columnNames.first(where: { ["alias", "m_nsaliasname", "alias_name"].contains($0.lowercased()) })
            let headCol = columnNames.first(where: { ["m_nsheadimgurl", "head_img_url", "avatar_url"].contains($0.lowercased()) })

            guard let finalIdCol = idCol else { continue }

            var selectFields = ["\"\(finalIdCol)\""]
            var nickIdx = -1, remarkIdx = -1, aliasIdx = -1, headIdx = -1

            if let nickCol {
                nickIdx = selectFields.count
                selectFields.append("\"\(nickCol)\"")
            }
            if let remarkCol {
                remarkIdx = selectFields.count
                selectFields.append("\"\(remarkCol)\"")
            }
            if let aliasCol {
                aliasIdx = selectFields.count
                selectFields.append("\"\(aliasCol)\"")
            }
            if let headCol {
                headIdx = selectFields.count
                selectFields.append("\"\(headCol)\"")
            }

            let query = "SELECT \(selectFields.joined(separator: ", ")) FROM \"\(table)\" WHERE \"\(finalIdCol)\" IS NOT NULL AND \"\(finalIdCol)\" != '';"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let usrName = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                    guard !usrName.isEmpty else { continue }

                    let nickName = nickIdx >= 0 ? (sqlite3_column_text(stmt, Int32(nickIdx)).map { String(cString: $0) } ?? "") : ""
                    let remark = remarkIdx >= 0 ? sqlite3_column_text(stmt, Int32(remarkIdx)).map { String(cString: $0) } : nil
                    let alias = aliasIdx >= 0 ? sqlite3_column_text(stmt, Int32(aliasIdx)).map { String(cString: $0) } : nil
                    let head = headIdx >= 0 ? sqlite3_column_text(stmt, Int32(headIdx)).map { String(cString: $0) } : nil

                    // 检查是否为当前登录用户本人
                    let isSelf = (usrName == accountID || usrName == normalizedAccountID || usrName.contains(baseAccountID))
                    if isSelf || (detectedMyNickname == nil && usrName.hasPrefix("wxid_") && usrName.contains(baseAccountID)) {
                        if !nickName.isEmpty { detectedMyNickname = nickName }
                        if let alias, !alias.isEmpty { detectedMyAlias = alias }
                    }

                    contacts.append(WeChatContact(id: usrName, nickname: nickName, remark: remark, avatarURL: head))
                }
                sqlite3_finalize(stmt)
            }

            if !contacts.isEmpty {
                break
            }
        }

        return (contacts, (detectedMyNickname, detectedMyAlias))
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

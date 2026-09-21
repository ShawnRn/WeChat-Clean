import SwiftUI
import Observation

public enum SortOption: String, CaseIterable, Identifiable, Sendable {
    case sizeDesc = "按大小 (从大到小)"
    case sizeAsc = "按大小 (从小到大)"
    case dateDesc = "按时间 (从新到旧)"
    case dateAsc = "按时间 (从旧到新)"
    case nameAsc = "按名称"

    public var id: String { rawValue }
}

public enum SizeFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "全部"
    case over10MB = "> 10 MB"
    case over50MB = "> 50 MB"
    case over100MB = "> 100 MB"
    case over500MB = "> 500 MB"

    public var id: String { rawValue }

    public var minBytes: Int64 {
        switch self {
        case .all: return 0
        case .over10MB: return 10 * 1024 * 1024
        case .over50MB: return 50 * 1024 * 1024
        case .over100MB: return 100 * 1024 * 1024
        case .over500MB: return 500 * 1024 * 1024
        }
    }
}

@Observable
@MainActor
public final class AppState {
    // 账号与路径探测
    public var accounts: [WeChatAccount] = []
    public var selectedAccount: WeChatAccount?
    public var isWeChatRunning: Bool = false
    public var detectionResult: DetectionResult = .notFound(WeChatDetector.defaultRootURL)
    public var customRootPath: String = "" {
        didSet {
            UserDefaults.standard.set(customRootPath, forKey: "customWeChatPath")
            refreshAccounts()
        }
    }

    // 分类与过滤
    public var selectedCategory: WeChatCategory = .all {
        didSet { scheduleFilterAndSort() }
    }
    public var isTableView: Bool = true
    public var tableSortOrder: [KeyPathComparator<WeChatFileItem>] = [
        KeyPathComparator(\.size, order: .reverse)
    ] {
        didSet { scheduleFilterAndSort() }
    }
    public var sizeFilter: SizeFilter = .all {
        didSet { scheduleFilterAndSort() }
    }
    public var searchText: String = "" {
        didSet { scheduleFilterAndSort() }
    }
    public var contactFilter: String? = nil {
        didSet { scheduleFilterAndSort() }
    }

    // 扫描与缓存结果
    public var allItems: [WeChatFileItem] = []
    public var itemMap: [String: WeChatFileItem] = [:]
    public var categorySizes: [WeChatCategory: Int64] = [:]
    
    // 过滤与展示结果（存储属性，完全脱离主线程渲染计算，彻底消除点击/多选卡顿）
    public var displayedItems: [WeChatFileItem] = []
    public var filteredItemCount: Int = 0
    public var currentCategorySize: Int64 = 0

    public var duplicateGroups: [DuplicateGroup] = []
    public var isDeduplicating: Bool = false
    public var scanProgress: ScanProgress = ScanProgress()

    // 选区（使用快速 Set 与增量体积统计，O(1) 响应）
    public var selectedItemIDs: Set<String> = []
    public var selectedTotalSize: Int64 = 0
    public var previewURL: URL?

    // 会话与联系人存储管理
    public var sessions: [WeChatSessionItem] = []
    public var isSessionMode: Bool = false
    public var selectedSessionIDs: Set<String> = []
    public var drillDownSession: WeChatSessionItem? = nil {
        didSet { scheduleFilterAndSort() }
    }

    // 虚拟分页限制
    public var displayLimit: Int = 300 {
        didSet { scheduleFilterAndSort() }
    }

    // 提示信息与全局弹窗
    public var alertMessage: String?
    public var showAlert: Bool = false
    public var showDatabaseKeySheet: Bool = false

    // 引擎与后台任务
    private let scanner = ScannerEngine()
    private let deduplicator = HardlinkDeduplicator()
    private let cleaner = CleanerEngine()
    private var filterSortTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?

    public init() {
        if let savedPath = UserDefaults.standard.string(forKey: "customWeChatPath"), !savedPath.isEmpty {
            self.customRootPath = savedPath
        }
        refreshAccounts()
    }

    public func refreshAccounts() {
        let rootURL: URL? = customRootPath.isEmpty ? nil : URL(fileURLWithPath: customRootPath)
        let result = WeChatDetector.detect(at: rootURL)
        self.detectionResult = result
        self.isWeChatRunning = WeChatDetector.isWeChatRunning()

        switch result {
        case .success(let detected):
            self.accounts = detected
            if selectedAccount == nil || !detected.contains(where: { $0.id == selectedAccount?.id }) {
                self.selectedAccount = detected.first
            }
            startScan()
        case .permissionDenied, .notFound:
            self.accounts = []
            self.selectedAccount = nil
            self.allItems = []
            self.itemMap = [:]
            self.categorySizes = [:]
            self.displayedItems = []
            self.filteredItemCount = 0
            self.currentCategorySize = 0
        }
    }

    public func promptForWeChatDirectory() {
        if let selectedURL = WeChatDetector.chooseWeChatDirectory() {
            self.customRootPath = selectedURL.path
            refreshAccounts()
        }
    }

    public func startScan() {
        guard let account = selectedAccount else { return }
        WeChatDatDecoder.shared.configure(with: account)
        WeChatContactManager.shared.switchAccount(to: account)
        let loadRes = WeChatContactManager.shared.loadContacts(for: account)
        if let nick = loadRes.myNickname, !nick.isEmpty {
            self.selectedAccount?.customNickname = nick
        }
        if let wechatId = loadRes.myWeChatID, !wechatId.isEmpty {
            self.selectedAccount?.customWeChatID = wechatId
        }
        if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
            if let nick = loadRes.myNickname, !nick.isEmpty {
                self.accounts[idx].customNickname = nick
            }
            if let wechatId = loadRes.myWeChatID, !wechatId.isEmpty {
                self.accounts[idx].customWeChatID = wechatId
            }
        }

        self.allItems = []
        self.itemMap = [:]
        self.categorySizes = [:]
        self.displayedItems = []
        self.filteredItemCount = 0
        self.currentCategorySize = 0
        self.selectedItemIDs = []
        self.selectedTotalSize = 0
        self.duplicateGroups = []
        self.displayLimit = 300
        self.scanProgress = ScanProgress(isScanning: true, statusMessage: "准备扫描...")

        scanTask?.cancel()
        scanTask = Task.detached(priority: .userInitiated) { [weak self, scanner] in
            guard let strongSelf = self else { return }

            let onProgress: @Sendable (ScanProgress) -> Void = { [weak strongSelf] progress in
                Task { @MainActor [weak strongSelf] in
                    guard let strongSelf, strongSelf.scanProgress.isScanning else { return }
                    strongSelf.scanProgress = progress
                }
            }

            let result = await scanner.scan(account: account, onProgress: onProgress)

            if Task.isCancelled { return }

            await MainActor.run { [weak strongSelf] in
                guard let strongSelf else { return }
                strongSelf.allItems = result.items
                strongSelf.itemMap = result.itemMap
                strongSelf.categorySizes = result.categorySizes
                strongSelf.sessions = result.sessions
                strongSelf.scanProgress = ScanProgress(
                    isScanning: false,
                    currentDirectory: "",
                    scannedCount: result.items.count,
                    totalBytes: result.totalSize,
                    statusMessage: "扫描完成，发现 \(result.items.count) 个项目"
                )

                if let idx = strongSelf.accounts.firstIndex(where: { $0.id == account.id }) {
                    strongSelf.accounts[idx].totalSize = result.totalSize
                }

                strongSelf.scheduleFilterAndSort()
                strongSelf.analyzeDuplicates()
            }
        }
    }

    /// 重新加载联系人数据库并刷新所有会话的联系人绑定与当前账号明文信息
    public func reloadContacts() {
        guard let account = selectedAccount else { return }
        let loadRes = WeChatContactManager.shared.loadContacts(for: account)
        if let nick = loadRes.myNickname, !nick.isEmpty {
            self.selectedAccount?.customNickname = nick
        }
        if let wechatId = loadRes.myWeChatID, !wechatId.isEmpty {
            self.selectedAccount?.customWeChatID = wechatId
        }
        if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
            if let nick = loadRes.myNickname, !nick.isEmpty {
                self.accounts[idx].customNickname = nick
            }
            if let wechatId = loadRes.myWeChatID, !wechatId.isEmpty {
                self.accounts[idx].customWeChatID = wechatId
            }
        }

        for i in 0..<sessions.count {
            let hash = sessions[i].id
            sessions[i].contact = WeChatContactManager.shared.contact(forChatMD5: hash)
        }
        scheduleFilterAndSort()
    }

    /// 获取指定会话哈希的显示名（优先联系人姓名/备注）
    public func sessionDisplayName(for hash: String) -> String {
        if let contact = WeChatContactManager.shared.contact(forChatMD5: hash) {
            return contact.displayName
        }
        if let session = sessions.first(where: { $0.id == hash }) {
            return session.effectiveName
        }
        return "会话 (\(hash.prefix(8)))"
    }

    /// 核心异步调度方法：将耗时的过滤与排序移至后台并发线程
    public func scheduleFilterAndSort() {
        filterSortTask?.cancel()

        let itemsSnapshot = self.allItems
        let categorySnapshot = self.selectedCategory
        let sizeFilterSnapshot = self.sizeFilter
        let searchSnapshot = self.searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let sortOrderSnapshot = self.tableSortOrder
        let limitSnapshot = self.displayLimit
        let drillDownSnapshot = self.drillDownSession?.id
        let contactFilterSnapshot = self.contactFilter

        filterSortTask = Task.detached(priority: .userInitiated) {
            if Task.isCancelled { return }

            // 1. 过滤
            var filtered: [WeChatFileItem] = []
            filtered.reserveCapacity(min(itemsSnapshot.count, 50_000))

            for item in itemsSnapshot {
                // 联系人筛选
                if let contactFilter = contactFilterSnapshot, item.sessionHash != contactFilter {
                    continue
                }

                // 会话下钻过滤：如果指定了会话，仅展示该会话下的附件
                if let drill = drillDownSnapshot, item.sessionHash != drill {
                    continue
                }

                // 分类过滤
                switch categorySnapshot {
                case .all: break
                case .largeFiles:
                    if item.size < 100 * 1024 * 1024 { continue }
                case .duplicates: break
                case .video:
                    if item.category != .video { continue }
                case .file:
                    if item.category != .file { continue }
                case .attach:
                    if item.category != .attach { continue }
                case .cache:
                    if item.category != .cache { continue }
                }

                // 大小过滤
                if sizeFilterSnapshot.minBytes > 0 && item.size < sizeFilterSnapshot.minBytes {
                    continue
                }

                // 搜索词过滤
                if !searchSnapshot.isEmpty && !item.name.lowercased().contains(searchSnapshot) {
                    continue
                }

                filtered.append(item)
            }

            if Task.isCancelled { return }

            let totalCount = filtered.count
            let totalBytes = filtered.reduce(0) { $0 + $1.size }

            // 2. 原生极速排序（原生闭包比反射 KeyPathComparator 快数十倍）
            if let primary = sortOrderSnapshot.first {
                let isReverse = (primary.order == .reverse)
                if primary.keyPath == \WeChatFileItem.size {
                    filtered.sort { isReverse ? $0.size > $1.size : $0.size < $1.size }
                } else if primary.keyPath == \WeChatFileItem.name {
                    filtered.sort {
                        let c = $0.name.localizedStandardCompare($1.name)
                        return isReverse ? (c == .orderedDescending) : (c == .orderedAscending)
                    }
                } else if primary.keyPath == \WeChatFileItem.modificationDate {
                    filtered.sort {
                        let t0 = $0.modificationDate.timeIntervalSince1970
                        let t1 = $1.modificationDate.timeIntervalSince1970
                        if isReverse {
                            return t0 > t1
                        } else {
                            // 升序时，将 1980 年前的无效 MS-DOS 时间排在最末尾
                            if t0 < 315532800 && t1 >= 315532800 { return false }
                            if t1 < 315532800 && t0 >= 315532800 { return true }
                            return t0 < t1
                        }
                    }
                } else if primary.keyPath == \WeChatFileItem.category.rawValue {
                    filtered.sort { isReverse ? $0.category.rawValue > $1.category.rawValue : $0.category.rawValue < $1.category.rawValue }
                } else {
                    filtered.sort(using: sortOrderSnapshot)
                }
            }

            if Task.isCancelled { return }

            let displayed = Array(filtered.prefix(limitSnapshot))

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.filteredItemCount = totalCount
                self.currentCategorySize = totalBytes
                self.displayedItems = displayed
            }
        }
    }

    public func analyzeDuplicates() {
        guard !isDeduplicating else { return }
        self.isDeduplicating = true
        let itemsSnapshot = self.allItems

        Task.detached(priority: .utility) { [weak self, deduplicator] in
            let groups = await deduplicator.findDuplicates(from: itemsSnapshot)

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.duplicateGroups = groups
                self.isDeduplicating = false
                self.categorySizes[.duplicates] = groups.reduce(0) { $0 + $1.reclaimableSize }
            }
        }
    }

    public func applyHardlinkDeduplication() {
        let result = deduplicator.applyHardlinks(for: duplicateGroups)
        let freedFormatted = ByteCountFormatter.string(fromByteCount: result.freedBytes, countStyle: .file)
        self.alertMessage = "成功去重 \(result.linkedCount) 个文件，释放 \(freedFormatted) 物理磁盘空间！微信内各处仍可正常打开。"
        self.showAlert = true
        startScan()
    }

    /// 高性能增量切换选中项 (O(1) 复杂度，彻底消灭点击卡顿)
    public func toggleSelection(for item: WeChatFileItem, isMultiSelect: Bool) {
        if isMultiSelect {
            if selectedItemIDs.contains(item.id) {
                selectedItemIDs.remove(item.id)
                selectedTotalSize -= item.size
            } else {
                selectedItemIDs.insert(item.id)
                selectedTotalSize += item.size
            }
        } else {
            if selectedItemIDs.contains(item.id) && selectedItemIDs.count == 1 {
                selectedItemIDs.removeAll()
                selectedTotalSize = 0
            } else {
                selectedItemIDs = [item.id]
                selectedTotalSize = item.size
            }
        }
    }

    public func selectAllFiltered() {
        self.selectedItemIDs = Set(displayedItems.map { $0.id })
        self.selectedTotalSize = displayedItems.reduce(0) { $0 + $1.size }
    }

    /// 全选当前分类及筛选条件下的全部项目（突破分页限制，如全部 194,294 项，61.62 GB）
    public func selectAllCategory() {
        let matchingItems = allItems.filter { item in
            if selectedCategory != .all && item.category != selectedCategory { return false }
            if let contact = contactFilter, item.sessionHash != contact { return false }
            if sizeFilter != .all && item.size < sizeFilter.minBytes { return false }
            if !searchText.isEmpty && !item.name.localizedCaseInsensitiveContains(searchText) { return false }
            return true
        }
        self.selectedItemIDs = Set(matchingItems.map { $0.id })
        self.selectedTotalSize = matchingItems.reduce(0) { $0 + $1.size }
    }

    public func clearSelection() {
        self.selectedItemIDs.removeAll()
        self.selectedTotalSize = 0
    }

    public func cleanSelected(preserveThumbnails: Bool = true) {
        let itemsToClean = selectedItemIDs.compactMap { itemMap[$0] }
        guard !itemsToClean.isEmpty else { return }

        let result = cleaner.clean(items: itemsToClean, preserveThumbnails: preserveThumbnails)
        let freedFormatted = ByteCountFormatter.string(fromByteCount: result.freedBytes, countStyle: .file)

        let deletedSet = Set(itemsToClean.map { $0.id })
        self.allItems.removeAll { deletedSet.contains($0.id) }
        for id in deletedSet {
            self.itemMap.removeValue(forKey: id)
        }

        // 增量更新分类体积缓存
        for item in itemsToClean {
            categorySizes[.all, default: 0] -= item.size
            categorySizes[item.category, default: 0] -= item.size
            if item.size >= 100 * 1024 * 1024 {
                categorySizes[.largeFiles, default: 0] -= item.size
            }
        }

        self.clearSelection()
        self.scheduleFilterAndSort()

        self.alertMessage = "成功将 \(result.deletedCount) 个文件移至废纸篓，释放 \(freedFormatted) 空间。"
        self.showAlert = true
    }

    public func loadMore() {
        displayLimit += 300
    }

    /// O(1) 字典查找分类大小
    public func categorySize(_ category: WeChatCategory) -> Int64 {
        categorySizes[category] ?? 0
    }

    // MARK: - 账号资料与会话管理方法

    public func updateAccountProfile(nickname: String, wechatId: String) {
        guard let account = selectedAccount else { return }
        WeChatDetector.saveAccountProfile(for: account.id, nickname: nickname, wechatId: wechatId)
        if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[idx].customNickname = nickname.trimmingCharacters(in: .whitespaces).isEmpty ? nil : nickname
            accounts[idx].customWeChatID = wechatId.trimmingCharacters(in: .whitespaces).isEmpty ? nil : wechatId
            self.selectedAccount = accounts[idx]
        }
    }

    public func updateSessionRemark(sessionID: String, remark: String) {
        guard let account = selectedAccount else { return }
        WeChatDetector.saveSessionRemark(for: account.id, sessionID: sessionID, remark: remark)
        if let idx = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[idx].customName = remark.trimmingCharacters(in: .whitespaces).isEmpty ? nil : remark
        }
        if drillDownSession?.id == sessionID {
            drillDownSession?.customName = remark.trimmingCharacters(in: .whitespaces).isEmpty ? nil : remark
        }
    }

    public func enterSessionDrillDown(session: WeChatSessionItem) {
        self.drillDownSession = session
        self.selectedCategory = .attach
        self.isSessionMode = false
    }

    public func exitSessionDrillDown() {
        self.drillDownSession = nil
        self.isSessionMode = true
    }

    public func cleanSelectedSessions() {
        guard !selectedSessionIDs.isEmpty else { return }
        let targetSessions = sessions.filter { selectedSessionIDs.contains($0.id) }
        var totalFreed: Int64 = 0
        var totalDeletedCount = 0

        for session in targetSessions {
            let sessionItems = allItems.filter { $0.sessionHash == session.id }
            let res = cleaner.clean(items: sessionItems, preserveThumbnails: false)
            totalFreed += res.freedBytes
            totalDeletedCount += res.deletedCount

            // 移入废纸篓整个会话目录
            cleaner.trashItem(at: session.url)
        }

        let deletedIDs = selectedSessionIDs
        self.sessions.removeAll { deletedIDs.contains($0.id) }
        self.allItems.removeAll { item in
            guard let hash = item.sessionHash else { return false }
            return deletedIDs.contains(hash)
        }
        self.selectedSessionIDs.removeAll()
        self.scheduleFilterAndSort()

        let freedStr = ByteCountFormatter.string(fromByteCount: totalFreed, countStyle: .file)
        self.alertMessage = "成功清理 \(targetSessions.count) 个会话，共 \(totalDeletedCount) 个文件，释放 \(freedStr) 空间。"
        self.showAlert = true
    }
}

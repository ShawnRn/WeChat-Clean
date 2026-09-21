import Foundation

/// 微信文件类别
public enum WeChatCategory: String, CaseIterable, Identifiable, Sendable {
    case all = "全部"
    case largeFiles = "大文件猎手"
    case duplicates = "重复文件瘦身"
    case video = "视频"
    case file = "聊天文件"
    case attach = "图片与附件"
    case cache = "系统缓存"

    public var id: String { rawValue }

    public var systemImage: String {
        switch self {
        case .all: return "tray.full"
        case .largeFiles: return "flame.fill"
        case .duplicates: return "doc.on.doc.fill"
        case .video: return "film.fill"
        case .file: return "doc.text.fill"
        case .attach: return "photo.fill"
        case .cache: return "archivebox.fill"
        }
    }
}

/// 单个文件项目
public struct WeChatFileItem: Identifiable, Sendable, Hashable {
    public let id: String // 通常使用文件标准化绝对路径
    public let url: URL
    public let name: String
    public let size: Int64
    public let category: WeChatCategory
    public let creationDate: Date
    public let modificationDate: Date
    public let thumbnailURL: URL?
    public let isHardlink: Bool
    public let inode: UInt64
    public let sessionHash: String?

    public init(
        url: URL,
        size: Int64,
        category: WeChatCategory,
        creationDate: Date,
        modificationDate: Date,
        thumbnailURL: URL? = nil,
        isHardlink: Bool = false,
        inode: UInt64 = 0,
        sessionHash: String? = nil
    ) {
        self.id = url.path
        self.url = url
        self.name = url.lastPathComponent
        self.size = size
        self.category = category
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.thumbnailURL = thumbnailURL
        self.isHardlink = isHardlink
        self.inode = inode
        self.sessionHash = sessionHash
    }

    /// 格式化后的大小（如 125.4 MB）
    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// 紧凑精致的修改日期格式（避免小窗口下文字过长截断）
    public var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yy/MM/dd HH:mm"
        return formatter.string(from: modificationDate)
    }
}

/// 重复文件组（同一文件在不同会话或多次转发）
public struct DuplicateGroup: Identifiable, Sendable {
    public let id: String // 内容 SHA256 哈希
    public let fileSize: Int64
    public var items: [WeChatFileItem]

    public init(id: String, fileSize: Int64, items: [WeChatFileItem]) {
        self.id = id
        self.fileSize = fileSize
        self.items = items
    }

    /// 已经硬链接归一（即所有项 inode 完全相同且非零）
    public var isAlreadyLinked: Bool {
        guard items.count > 1 else { return true }
        let firstInode = items[0].inode
        guard firstInode != 0 else { return false }
        return items.allSatisfy { $0.inode == firstInode }
    }

    /// 预计可释放的物理空间
    public var reclaimableSize: Int64 {
        if isAlreadyLinked { return 0 }
        return fileSize * Int64(items.count - 1)
    }

    public var formattedReclaimableSize: String {
        ByteCountFormatter.string(fromByteCount: reclaimableSize, countStyle: .file)
    }
}

/// 扫描进度状态
public struct ScanProgress: Sendable {
    public var isScanning: Bool = false
    public var currentDirectory: String = ""
    public var scannedCount: Int = 0
    public var totalBytes: Int64 = 0
    public var statusMessage: String = "就绪"

    public var formattedTotalBytes: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}

/// 微信账号
public struct WeChatAccount: Identifiable, Sendable, Hashable {
    public let id: String
    public let url: URL
    public let displayName: String
    public var customNickname: String?
    public var customWeChatID: String?
    public var avatarURL: String?
    public var totalSize: Int64 = 0

    public init(
        id: String,
        url: URL,
        displayName: String,
        customNickname: String? = nil,
        customWeChatID: String? = nil,
        avatarURL: String? = nil,
        totalSize: Int64 = 0
    ) {
        self.id = id
        self.url = url
        self.displayName = displayName
        self.customNickname = customNickname
        self.customWeChatID = customWeChatID
        self.avatarURL = avatarURL
        self.totalSize = totalSize
    }

    /// 优先显示自定义昵称，否则显示原始显示名
    public var displayTitle: String {
        if let nick = customNickname, !nick.trimmingCharacters(in: .whitespaces).isEmpty {
            return nick
        }
        return displayName
    }

    /// 次级标题：微信号或原始 wxid
    public var displaySubtitle: String {
        if let wxid = customWeChatID, !wxid.trimmingCharacters(in: .whitespaces).isEmpty {
            return "微信号: \(wxid)"
        }
        return id
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }
}

/// 会话/联系人存储项（对应 msg/attach 下各个 talker 哈希目录）
public struct WeChatSessionItem: Identifiable, Sendable, Hashable {
    public let id: String // 会话哈希 (如 62cc3bb1bf3531344e16f6a0ab85da8f)
    public let url: URL
    public var size: Int64
    public var fileCount: Int
    public var latestDate: Date
    public var customName: String? // 用户备注的联系人/群名称 (如 🥣•v•🥣)
    public var firstThumbnailURL: URL? // 预览缩略图
    public var contact: WeChatContact? // 关联的真实微信联系人

    public init(
        id: String,
        url: URL,
        size: Int64 = 0,
        fileCount: Int = 0,
        latestDate: Date = Date.distantPast,
        customName: String? = nil,
        firstThumbnailURL: URL? = nil,
        contact: WeChatContact? = nil
    ) {
        self.id = id
        self.url = url
        self.size = size
        self.fileCount = fileCount
        self.latestDate = latestDate
        self.customName = customName
        self.firstThumbnailURL = firstThumbnailURL
        self.contact = contact
    }

    public var effectiveName: String {
        if let contact {
            return contact.displayName
        }
        if let name = customName, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return name
        }
        let shortHash = id.prefix(8)
        return "会话 (\(shortHash))"
    }

    public var contactSubtitle: String {
        if let contact {
            return contact.id
        }
        return id
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    public var formattedDate: String {
        if latestDate == Date.distantPast { return "未知" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter.string(from: latestDate)
    }
}

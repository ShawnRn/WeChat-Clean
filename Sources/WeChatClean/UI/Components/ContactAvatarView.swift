import SwiftUI
import AppKit
import CryptoKit

/// 头像缓存管理器（内存 NSCache + 本地沙盒磁盘双层缓存，极速加载微信 CDN 头像）
@MainActor
public final class AvatarImageLoader: @unchecked Sendable {
    public static let shared = AvatarImageLoader()

    private let memoryCache = NSCache<NSString, NSImage>()
    private let diskCacheDir: URL
    private var activeTasks: [String: Task<NSImage?, Never>] = [:]

    private init() {
        memoryCache.countLimit = 1000
        memoryCache.totalCostLimit = 50 * 1024 * 1024 // 50MB 内存上限

        let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        diskCacheDir = cachesURL.appendingPathComponent("WeChatClean/Avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskCacheDir, withIntermediateDirectories: true)
    }

    /// 同步读取内存或磁盘缓存
    public func cachedImage(for urlString: String) -> NSImage? {
        if let mem = memoryCache.object(forKey: urlString as NSString) {
            return mem
        }
        let diskFile = diskURL(for: urlString)
        if FileManager.default.fileExists(atPath: diskFile.path),
           let data = try? Data(contentsOf: diskFile),
           let img = NSImage(data: data) {
            memoryCache.setObject(img, forKey: urlString as NSString, cost: data.count)
            return img
        }
        return nil
    }

    /// 异步加载头像
    public func loadImage(for urlString: String) async -> NSImage? {
        if let cached = cachedImage(for: urlString) {
            return cached
        }

        if let existing = activeTasks[urlString] {
            return await existing.value
        }

        let task = Task<NSImage?, Never> {
            guard let url = URL(string: urlString) else { return nil }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.cachePolicy = .returnCacheDataElseLoad

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                      let image = NSImage(data: data) else {
                    return nil
                }

                // 写入磁盘缓存
                let diskFile = self.diskURL(for: urlString)
                try? data.write(to: diskFile, options: .atomic)

                await MainActor.run {
                    self.memoryCache.setObject(image, forKey: urlString as NSString, cost: data.count)
                }
                return image
            } catch {
                return nil
            }
        }

        activeTasks[urlString] = task
        let result = await task.value
        activeTasks.removeValue(forKey: urlString)
        return result
    }

    private func diskURL(for urlString: String) -> URL {
        let digest = Insecure.MD5.hash(data: Data(urlString.utf8))
        let hashStr = digest.map { String(format: "%02x", $0) }.joined()
        return diskCacheDir.appendingPathComponent("\(hashStr).jpg")
    }
}

/// 微信通用联系人与个人头像组件（原生异步加载、双层缓存、平滑淡入、优雅降级）
public struct ContactAvatarView: View {
    public let avatarURL: String?
    public let displayName: String
    public let identifier: String? // wxid 或群聊 ID
    public let size: CGFloat
    public let isCircle: Bool

    @State private var loadedImage: NSImage?

    public init(
        avatarURL: String?,
        displayName: String = "",
        identifier: String? = nil,
        size: CGFloat = 32,
        isCircle: Bool = false
    ) {
        self.avatarURL = avatarURL
        self.displayName = displayName
        self.identifier = identifier
        self.size = size
        self.isCircle = isCircle
        if let avatarURL, !avatarURL.isEmpty {
            _loadedImage = State(initialValue: AvatarImageLoader.shared.cachedImage(for: avatarURL))
        }
    }

    public var body: some View {
        ZStack {
            if let image = loadedImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(avatarShape)
                    .overlay {
                        avatarShape
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                    }
            } else {
                fallbackView
            }
        }
        .frame(width: size, height: size)
        .task(id: avatarURL) {
            guard let url = avatarURL, !url.trimmingCharacters(in: .whitespaces).isEmpty else {
                loadedImage = nil
                return
            }
            if loadedImage == nil {
                if let cached = AvatarImageLoader.shared.cachedImage(for: url) {
                    self.loadedImage = cached
                } else {
                    let image = await AvatarImageLoader.shared.loadImage(for: url)
                    withAnimation(.easeInOut(duration: 0.2)) {
                        self.loadedImage = image
                    }
                }
            }
        }
    }

    private var avatarShape: AnyShape {
        if isCircle {
            return AnyShape(Circle())
        } else {
            return AnyShape(RoundedRectangle(cornerRadius: max(size * 0.2, 4), style: .continuous))
        }
    }

    // MARK: - 降级占位视觉 (首字徽章、群聊图标或默认头像)
    @ViewBuilder
    private var fallbackView: some View {
        let isChatroom = identifier?.hasSuffix("@chatroom") ?? false

        ZStack {
            avatarShape
                .fill(avatarBgColor(isChatroom: isChatroom))

            if isChatroom {
                Image(systemName: "person.3.fill")
                    .font(.system(size: size * 0.44))
                    .foregroundStyle(.white.opacity(0.92))
            } else {
                let initial = initialCharacter(from: displayName)
                if !initial.isEmpty {
                    Text(initial)
                        .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.46))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .overlay {
            avatarShape
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }

    /// 提取名称首字符
    private func initialCharacter(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "" }
        return String(first).uppercased()
    }

    /// 根据名称与 ID 哈希派生平滑美观的背景色
    private func avatarBgColor(isChatroom: Bool) -> Color {
        if isChatroom {
            return Color(red: 0.22, green: 0.58, blue: 0.45) // 微信经典群聊暗墨绿
        }

        let key = (!displayName.isEmpty ? displayName : (identifier ?? ""))
        guard !key.isEmpty else {
            return Color.accentColor.opacity(0.15)
        }

        // 精选 8 种高雅护眼马卡龙/经典色阶
        let palette: [Color] = [
            Color(red: 0.28, green: 0.52, blue: 0.92), // 经典蓝
            Color(red: 0.36, green: 0.72, blue: 0.36), // 微信绿
            Color(red: 0.92, green: 0.48, blue: 0.32), // 珊瑚橙
            Color(red: 0.62, green: 0.42, blue: 0.88), // 薰衣草紫
            Color(red: 0.20, green: 0.68, blue: 0.72), // 湖水青
            Color(red: 0.88, green: 0.36, blue: 0.52), // 玫瑰粉
            Color(red: 0.84, green: 0.62, blue: 0.20), // 琥珀黄
            Color(red: 0.45, green: 0.55, blue: 0.72)  // 莫兰迪灰蓝
        ]

        let hash = abs(key.hashValue)
        return palette[hash % palette.count]
    }
}

import Foundation
import AppKit
@preconcurrency import Quartz

@MainActor
public final class QuickLookManager: NSObject {
    public static let shared = QuickLookManager()

    public var currentURL: URL?
    private var frameCache: [URL: CGRect] = [:]
    private var imageCache: [URL: NSImage] = [:]
    private var originalURLForPreview: [URL: URL] = [:]
    private(set) var sourceWindow: NSWindow?

    override private init() {
        super.init()
    }

    public func setFrame(_ frame: CGRect, for url: URL) {
        if frame != .zero {
            frameCache[url] = frame
        }
    }

    public func setImage(_ image: NSImage, for url: URL) {
        imageCache[url] = image
    }

    public func updateSourceWindow(_ window: NSWindow?) {
        guard let window = window, !(window is QLPreviewPanel) else { return }
        self.sourceWindow = window
    }

    /// 解析适于 QuickLook 预览的项目（.dat 文件自动解密为临时图片）
    private func resolvePreviewURL(for url: URL) -> URL {
        guard url.pathExtension.lowercased() == "dat" else {
            return url
        }

        let baseName = url.deletingPathExtension().lastPathComponent
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())

        // 尝试从内存缓存获取或解码
        if let data = WeChatDatDecoder.shared.decodeData(at: url) {
            var ext = "jpg"
            if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
                ext = "png"
            } else if data.starts(with: [0x47, 0x49, 0x46]) {
                ext = "gif"
            }
            let tempFile = tempDir.appendingPathComponent("wechat_preview_\(baseName).\(ext)")
            try? data.write(to: tempFile)
            originalURLForPreview[tempFile] = url
            return tempFile
        }

        return url
    }

    public func togglePreview(for url: URL?) {
        guard let panel = QLPreviewPanel.shared() else { return }

        updateSourceWindow(NSApp.keyWindow)

        if panel.isVisible {
            if let current = currentURL, (current == url || originalURLForPreview[current] == url) {
                panel.orderOut(nil)
                currentURL = nil
                return
            }
        }

        guard let url = url else {
            panel.orderOut(nil)
            currentURL = nil
            return
        }

        let previewURL = resolvePreviewURL(for: url)
        currentURL = previewURL
        panel.dataSource = self
        panel.delegate = self

        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    public func updatePreviewIfVisible(for url: URL?) {
        guard let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        updateSourceWindow(NSApp.keyWindow)
        guard let url = url else {
            panel.orderOut(nil)
            currentURL = nil
            return
        }
        let previewURL = resolvePreviewURL(for: url)
        currentURL = previewURL
        panel.reloadData()
    }
}

// MARK: - QLPreviewPanelDataSource & Delegate (从哪来回哪去动画，对齐 MotrixMac)

extension QuickLookManager: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        return currentURL != nil ? 1 : 0
    }

    public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        return currentURL as (QLPreviewItem)?
    }

    public func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let previewURL = (item as? URL) ?? ((item as? NSURL) as URL?) else { return .zero }
        let lookupURL = originalURLForPreview[previewURL] ?? previewURL
        guard let itemFrame = frameCache[lookupURL] else {
            return .zero
        }

        let window = sourceWindow ?? NSApp.keyWindow
        guard let window else { return .zero }

        // 翻转坐标系：SwiftUI (Top-left) -> AppKit (Bottom-left)
        let windowHeight = window.frame.height
        let appKitY = windowHeight - itemFrame.origin.y - itemFrame.size.height
        let rectInWindow = NSRect(x: itemFrame.origin.x, y: appKitY, width: itemFrame.size.width, height: itemFrame.size.height)

        return window.convertToScreen(rectInWindow)
    }

    public func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: QLPreviewItem!, contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        guard let url = (item as? URL) ?? ((item as? NSURL) as URL?) else { return nil }
        let lookupURL = originalURLForPreview[url] ?? url
        let image = imageCache[lookupURL] ?? ThumbnailStore.shared.thumbnails[lookupURL] ?? ThumbnailCache.shared.image(for: lookupURL) ?? NSWorkspace.shared.icon(forFile: lookupURL.path)

        let targetSize = NSSize(width: 32, height: 32)
        let roundedImage = NSImage(size: targetSize, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            path.addClip()

            let originalSize = image.size
            if originalSize.width > 0 && originalSize.height > 0 {
                let aspectWidth = targetSize.width / originalSize.width
                let aspectHeight = targetSize.height / originalSize.height
                let maxAspect = max(aspectWidth, aspectHeight)

                let drawWidth = originalSize.width * maxAspect
                let drawHeight = originalSize.height * maxAspect
                let drawX = (targetSize.width - drawWidth) / 2
                let drawY = (targetSize.height - drawHeight) / 2

                image.draw(in: NSRect(x: drawX, y: drawY, width: drawWidth, height: drawHeight),
                           from: .zero,
                           operation: .sourceOver,
                           fraction: 1.0)
            } else {
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            return true
        }
        return roundedImage
    }
}

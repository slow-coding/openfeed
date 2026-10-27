import SwiftUI
import AppKit

/// 缩略图：仓库的头像（20pt 圆），拿不到就退成一颗带图标的点。
/// OG 卡片在这个尺寸下只剩糊字，试过一轮，收益还不如一个干净的头像。
final class ThumbCache {
    static let shared = ThumbCache()
    private let memory = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "openfeed.thumbs", qos: .utility, attributes: .concurrent)
    private static let gate = DispatchSemaphore(value: 4)

    private var directory: URL { Paths.avatars }

    /// 清空图片缓存时连内存里那份一起丢掉。
    func forget() {
        memory.removeAllObjects()
    }

    func cached(_ url: URL) -> NSImage? {
        memory.object(forKey: url.absoluteString as NSString)
    }

    func load(_ url: URL, size: CGSize, completion: @escaping (NSImage?) -> Void) {
        let key = url.absoluteString as NSString
        if let hit = memory.object(forKey: key) {
            completion(hit)
            return
        }
        let file = directory.appendingPathComponent(Self.fileName(url))
        if let image = NSImage(contentsOf: file), image.size.width > 0 {
            memory.setObject(image, forKey: key)
            completion(image)
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            Self.gate.wait()
            let data = try? Data(contentsOf: url)
            let image = data.flatMap { NSImage(data: $0) }.flatMap { Self.resized($0, to: size) }
            if let image {
                self.memory.setObject(image, forKey: key)
                if let png = image.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) })?
                    .representation(using: .png, properties: [:]) {
                    try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                    try? png.write(to: file)
                }
            }
            Self.gate.signal()
            DispatchQueue.main.async { completion(image) }
        }
    }

    private static func fileName(_ url: URL) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in url.absoluteString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16) + ".png"
    }

    /// 按像素画，不靠 NSImage.size 缩放：缩出来的边不发糊。
    private static func resized(_ image: NSImage, to size: CGSize) -> NSImage? {
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let target = NSRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale))
        let source = image.size
        let ratio = max(target.width / source.width, target.height / source.height)
        let draw = NSRect(
            x: (target.width - source.width * ratio) / 2,
            y: (target.height - source.height * ratio) / 2,
            width: source.width * ratio,
            height: source.height * ratio
        )
        image.draw(in: draw, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: size)
        out.addRepresentation(rep)
        return out
    }
}

struct RowIcon: View {
    let item: FeedItem
    static let side: CGFloat = 20

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.side, height: Self.side)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(T.lane(item.lane).opacity(0.16))
                Image(systemName: glyph)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(T.lane(item.lane).opacity(0.9))
            }
        }
        .frame(width: Self.side, height: Self.side)
        .overlay(Circle().strokeBorder(T.hairline, lineWidth: 0.5))
        .task(id: item.id) {
            guard let url = item.avatarURL else { return }
            if let hit = ThumbCache.shared.cached(url) {
                image = hit
                return
            }
            ThumbCache.shared.load(url, size: CGSize(width: Self.side, height: Self.side)) { loaded in
                if let loaded { image = loaded }
            }
        }
    }

    private var glyph: String {
        switch item.kind {
        case .repo: return "chevron.left.forwardslash.chevron.right"
        case .release: return "tag.fill"
        case .story: return "text.bubble.fill"
        }
    }
}

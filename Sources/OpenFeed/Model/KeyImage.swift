import Foundation
import AppKit

/// 从 README 里挖出「最关键的那张图」。
/// 这条路是为这台机器定制的：URLSession 连 github.com / raw.githubusercontent.com 会挂死，
/// 所以文件内容一律走 api.github.com 的 contents/readme 接口（base64），只有外部图床才直接下。
enum KeyImage {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.httpAdditionalHeaders = ["User-Agent": "OpenFeed/1.0"]
        return URLSession(configuration: config)
    }()

    /// 徽章、统计图、赞助商按钮，都不是「产品长什么样」。
    private static let banned: [String] = [
        "shields.io", "badge", "travis", "codecov", "coveralls", "badgen", "appveyor",
        "github.com/workflows", "contrib.rocks", "forthebadge", "star-history",
        "visitor-badge", "hits.dwyl", "profile-counter", "open-collective", "paypal",
        "buymeacoffee", "ko-fi", "patreon", "discord.gg", ".svg"
    ]

    /// 返回可缓存的数据；没有图也落一条空标记，别每次悬停都重跑一遍。
    static func resolve(item: FeedItem, token: String?) async -> Data? {
        guard let slug = item.repoSlug else { return nil }
        // 同一个仓库解析过一次就不再解析：README 不会天天换主图。
        if let hit = ImageStore.shared.cached("key|\(slug)") { return hit }
        if ImageStore.shared.cached("none|\(slug)") != nil { return nil }
        if let key = item.keyImagePath, key != "-" {
            if let hit = ImageStore.shared.cached("\(slug)|\(key)") { return hit }
        }
        // README 一天里已经取过一次就走盘上那份，不再费一次接口往返。
        guard let markdown = await readmeText(slug: slug, token: token) else { return nil }
        let candidates = images(in: markdown).filter { candidate in
            let lowered = candidate.lowercased()
            return !banned.contains { lowered.contains($0) }
        }
        // 「没图」要下结论才落：只有服务器明确说没有、或拿到的确实不能用才算。
        // 超时、断网这种没走到的先不落——一旦落了它就一天翻不了身。
        var settled = candidates.isEmpty
        for source in candidates.prefix(3) {
            switch await fetch(source, slug: slug, token: token) {
            case .bytes(let data):
                if data.count > 8_000 {
                    _ = ImageStore.shared.store(data, key: "\(slug)|\(source)", itemID: item.id)
                    _ = ImageStore.shared.store(data, key: "key|\(slug)", itemID: item.id)
                    return data
                }
                settled = true          // 拿到了，但小到放不大
            case .absent:
                settled = true
            case .unknown:
                continue
            }
        }
        // shortcut: 图在 Git LFS 里的（拿到的是指针文本）算没图；真碰到了再补 media.githubusercontent。
        if settled {
            _ = ImageStore.shared.store(Data(), key: "none|\(slug)", itemID: item.id)
        }
        return nil
    }

    /// 面板上的图都提前备好：等鼠标停上去再解析，要等一两秒。
    /// 不分种类：版本条目也得按仓库名找一遍 README，漏了它悬停时照样得等。
    /// 列表只留两天，所以这里不用再封顶；抓过的一律从盘上命中。
    static func prewarm(items: [FeedItem]) async {
        var queue = items.makeIterator()
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            while running < 5, let item = queue.next() {
                group.addTask { _ = await display(item) }
                running += 1
            }
            while await group.next() != nil {
                if let item = queue.next() {
                    group.addTask { _ = await display(item) }
                }
            }
        }
    }

    /// 详情卡用的图：README 主图 → GitHub 分享卡 → 头像。
    static func display(_ item: FeedItem) async -> Data? {
        if let data = await resolve(item: item, token: Auth.token) { return data }

        if let url = item.imageURL {
            let key = "og|\(url.absoluteString)"
            if let hit = ImageStore.shared.cached(key) { return hit }
            if let (data, response) = try? await session.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200, data.count < 6_000_000 {
                _ = ImageStore.shared.store(data, key: key, itemID: item.id)
                return data
            }
        }

        if let url = item.avatarURL {
            let big = URL(string: url.absoluteString.replacingOccurrences(of: "&s=80", with: "&s=400")) ?? url
            let key = "avatar|\(big.absoluteString)"
            if let hit = ImageStore.shared.cached(key) { return hit }
            if let (data, response) = try? await session.data(from: big),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                _ = ImageStore.shared.store(data, key: key, itemID: item.id)
                return data
            }
        }
        return nil
    }

    static func images(in markdown: String) -> [String] {
        var found: [String] = []
        let patterns = [
            "!\\[[^\\]]*\\]\\(([^)\\s]+)",
            "<img[^>]+src=[\"']([^\"']+)[\"']"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
            for match in regex.matches(in: markdown, range: range) {
                guard match.numberOfRanges > 1,
                      let captured = Range(match.range(at: 1), in: markdown) else { continue }
                found.append(String(markdown[captured]))
            }
        }
        // 按出现顺序排：README 里第一张通常就是产品图 / logo
        let positions = found.map { markdown.distance(from: markdown.startIndex, to: markdown.range(of: $0)?.lowerBound ?? markdown.startIndex) }
        return zip(found, positions).sorted { $0.1 < $1.1 }.map { $0.0 }
    }

    // MARK: - 取 README

    /// README 原文：摘要和找图都要它，落一份在盘上，一天里同一个仓库只取一次。
    static func readmeText(slug: String, token: String?) async -> String? {
        guard !slug.isEmpty else { return nil }
        let file = Paths.readmes.appendingPathComponent(hash(slug) + ".md")
        if let text = try? String(contentsOf: file, encoding: .utf8), !text.isEmpty { return text }
        guard let text = await readme(slug: slug, token: token) else { return nil }
        try? FileManager.default.createDirectory(at: Paths.readmes, withIntermediateDirectories: true)
        try? text.write(to: file, atomically: true, encoding: .utf8)
        return text
    }

    static func hash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }

    private static func readme(slug: String, token: String?) async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/\(slug)/readme") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let payload = try? JSONDecoder.openFeed.decode(Readme.self, from: data),
              let raw = Data(base64Encoded: payload.content, options: .ignoreUnknownCharacters),
              let text = String(data: raw, encoding: .utf8)
        else { return nil }
        return text
    }

    // MARK: - 取图

    /// 一次取图的结果：拿到字节 / 服务器明确没有 / 根本没走到。
    private enum Fetched {
        case bytes(Data)
        case absent
        case unknown
    }

    /// 绝对链接能直连就直连：contents 接口对 1MB 以上的文件只回 size、不回内容，
    /// 而 raw.githubusercontent 实际能跑（1.6MB 两秒），「它会挂死」是旧结论。
    private static func fetch(_ source: String, slug: String, token: String?) async -> Fetched {
        guard let url = URL(string: source), let host = url.host else {
            return await viaContents(path: source, slug: slug, token: token)
        }
        if host == "raw.githubusercontent.com" || host == "media.githubusercontent.com" {
            return await direct(url)
        }
        if host == "github.com" {
            let parts = url.path.split(separator: "/").map(String.init)
            // /o/r/blob|raw/<branch>/<path> → raw
            if let index = parts.firstIndex(where: { $0 == "raw" || $0 == "blob" }), parts.count > index + 2,
               let raw = URL(string: "https://raw.githubusercontent.com/\(parts[0])/\(parts[1])/\(parts[index + 1])/"
                             + parts.dropFirst(index + 2).joined(separator: "/")) {
                return await direct(raw)
            }
            // /user-attachments/... 不是仓库路径，只能直连
            if parts.count >= 2, parts[0] != "user-attachments" {
                return await viaContents(path: parts.dropFirst(2).joined(separator: "/"),
                                         slug: "\(parts[0])/\(parts[1])", token: token)
            }
            return await direct(url)
        }
        return await direct(url)
    }

    private static func direct(_ url: URL) async -> Fetched {
        guard let (data, response) = try? await session.data(from: url),
              let code = (response as? HTTPURLResponse)?.statusCode
        else { return .unknown }
        if code == 404 || code == 410 { return .absent }
        guard code == 200, data.count < 6_000_000, NSImage(data: data) != nil else { return .absent }
        return .bytes(downscaled(data) ?? data)
    }

    /// 相对路径 → contents 接口拿 base64；接口不给内容（超过 1MB）就换 raw 直连。
    private static func viaContents(path raw: String, slug: String, token: String?) async -> Fetched {
        var path = raw
        if path.hasPrefix("./") { path.removeFirst(2) }
        if path.hasPrefix("/") { path.removeFirst() }
        path = path.components(separatedBy: "?").first ?? path
        guard !path.isEmpty,
              let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.github.com/repos/\(slug)/contents/\(encoded)")
        else { return .absent }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await session.data(for: request),
              let code = (response as? HTTPURLResponse)?.statusCode
        else { return .unknown }
        if code == 404 { return .absent }
        if code == 200,
           let payload = try? JSONDecoder.openFeed.decode(Contents.self, from: data),
           payload.size < 4_000_000,
           let bytes = Data(base64Encoded: payload.content, options: .ignoreUnknownCharacters),
           NSImage(data: bytes) != nil {
            return .bytes(downscaled(bytes) ?? bytes)
        }
        return await direct(URL(string: "https://raw.githubusercontent.com/\(slug)/HEAD/\(encoded)")!)
    }

    /// 详情卡最宽 360pt，2 倍图，再大就是白占内存。
    private static func downscaled(_ data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        let maxWidth: CGFloat = 760
        guard image.size.width > maxWidth else { return data }
        let ratio = maxWidth / image.size.width
        let size = NSSize(width: maxWidth, height: image.size.height * ratio)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return data }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? data
    }

    private struct Readme: Decodable {
        let content: String
        let path: String
    }

    private struct Contents: Decodable {
        let content: String
        let size: Int
    }
}

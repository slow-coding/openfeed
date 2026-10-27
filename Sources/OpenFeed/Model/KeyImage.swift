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

    /// 返回可缓存的数据；解析失败返回 nil，并让调用方把结论记下来别反复重试。
    static func resolve(item: FeedItem, token: String?) async -> Data? {
        guard let slug = item.repoSlug else { return nil }
        // 同一个仓库解析过一次就不再解析：README 不会天天换主图。
        if let hit = ImageStore.shared.cached("key|\(slug)") { return hit }
        if let key = item.keyImagePath, key != "-" {
            if let hit = ImageStore.shared.cached("\(slug)|\(key)") { return hit }
        }
        guard let markdown = await readme(slug: slug, token: token) else { return nil }
        let candidates = images(in: markdown).filter { candidate in
            let lowered = candidate.lowercased()
            return !banned.contains { lowered.contains($0) }
        }
        for source in candidates.prefix(3) {
            if let data = await download(source, slug: slug, token: token), data.count > 8_000 {
                _ = ImageStore.shared.store(data, key: "\(slug)|\(source)", itemID: item.id)
                _ = ImageStore.shared.store(data, key: "key|\(slug)", itemID: item.id)
                return data
            }
        }
        return nil
    }

    /// 拉完就先把最上面十几条的图备好：等鼠标停上去再解析，要等两三秒。
    static func prewarm(items: [FeedItem], limit: Int) async {
        let targets = items
            .filter { $0.kind == .repo }
            .prefix(limit)
        var queue = targets.makeIterator()
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            while running < 3, let item = queue.next() {
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

    private static func download(_ source: String, slug: String, token: String?) async -> Data? {
        if let url = URL(string: source), let host = url.host {
            if host.contains("githubusercontent.com"), host.contains("raw.") || host == "github.com" {
                return await contentsFile(path: source, slug: slug, token: token)
            }
            if host == "github.com" {
                return await contentsFile(path: source, slug: slug, token: token)
            }
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200, data.count < 6_000_000
            else { return nil }
            return downscaled(data)
        }
        return await contentsFile(path: source, slug: slug, token: token)
    }

    /// 相对路径 / raw 链接 → contents 接口拿 base64。
    private static func contentsFile(path raw: String, slug: String, token: String?) async -> Data? {
        var path = raw
        if path.hasPrefix("./") { path.removeFirst(2) }
        if path.hasPrefix("/") { path.removeFirst() }
        // https://raw.githubusercontent.com/o/r/main/assets/x.png → assets/x.png
        if let range = path.range(of: "raw.githubusercontent.com/") {
            let rest = path[range.upperBound...]
            let parts = rest.split(separator: "/").map(String.init)
            if parts.count > 3 { path = parts.dropFirst(3).joined(separator: "/") }
        }
        // https://github.com/o/r/raw/main/assets/x.png （或 /blob/）
        if path.hasPrefix("https://github.com/") {
            let parts = path.replacingOccurrences(of: "https://github.com/", with: "")
                .split(separator: "/").map(String.init)
            if let index = parts.firstIndex(where: { $0 == "raw" || $0 == "blob" }), parts.count > index + 2 {
                path = parts.dropFirst(index + 2).joined(separator: "/")
            }
        }
        path = path.components(separatedBy: "?").first ?? path
        guard !path.isEmpty,
              let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.github.com/repos/\(slug)/contents/\(encoded)")
        else { return nil }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let payload = try? JSONDecoder.openFeed.decode(Contents.self, from: data),
              payload.size < 4_000_000,
              let raw = Data(base64Encoded: payload.content, options: .ignoreUnknownCharacters)
        else { return nil }
        return downscaled(raw)
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

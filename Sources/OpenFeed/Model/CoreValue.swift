import Foundation

/// 「这东西到底做了什么事」——一句话。用 DeepSeek 把 README 的开头压成一句中文，
/// 结果按条目 id 存下来，同一个项目一辈子只算一次。
enum CoreValue {
    private static var cache: [String: String]?
    private static let lock = NSLock()

    // MARK: - 缓存的结论

    static func cached(_ id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if cache == nil { cache = load() }
        return cache?[id]
    }

    static func remember(_ id: String, line: String) {
        lock.lock()
        if cache == nil { cache = load() }
        cache?[id] = line
        let snapshot = cache ?? [:]
        lock.unlock()
        guard let data = try? JSONEncoder.openFeed.encode(snapshot) else { return }
        try? data.write(to: Paths.summaries, options: .atomic)
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: Paths.summaries),
              let decoded = try? JSONDecoder.openFeed.decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    // MARK: - 生成

    static func line(for item: FeedItem) async -> String? {
        if let hit = cached(item.id) { return hit }
        guard let key = Self.apiKey else { return nil }
        let text: String?
        switch item.kind {
        case .repo:
            let readme = await KeyImage.readmeText(slug: item.repoSlug ?? "", token: Auth.token) ?? ""
            text = await ask(key: key, system: repoPrompt, user: repoInput(item, readme: readme))
        case .release:
            text = await ask(key: key, system: releasePrompt,
                             user: "项目：\(item.subtitle)\n这次改了什么：\(item.title)\n更新说明：\(item.summary)")
        case .story:
            return nil
        }
        guard let text, !text.isEmpty, !text.contains("看不清") else { return nil }
        let cleaned = clean(text)
        guard cleaned.count >= 4 else { return nil }
        remember(item.id, line: cleaned)
        return cleaned
    }

    /// 拉完一批先把仓库的一句话补上：等鼠标停上去再算，要等两秒。
    static func prewarm(items: [FeedItem], limit: Int) async {
        guard apiKey != nil else { return }
        let targets = items.filter { item in
            item.kind == .repo && cached(item.id) == nil
        }.prefix(limit)
        var queue = targets.makeIterator()
        await withTaskGroup(of: (String, String?).self) { group in
            var running = 0
            while running < 3, let item = queue.next() {
                group.addTask { (item.id, await line(for: item)) }
                running += 1
            }
            while let done = await group.next() {
                if let next = queue.next() {
                    group.addTask { (next.id, await line(for: next)) }
                }
                _ = done
            }
        }
    }

    private static func clean(_ text: String) -> String {
        var line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        line = line.replacingOccurrences(of: "\"", with: "")
        line = line.replacingOccurrences(of: "「", with: "").replacingOccurrences(of: "」", with: "")
        if line.hasSuffix("。") { line.removeLast() }
        return line
    }

    private static func repoInput(_ item: FeedItem, readme: String) -> String {
        """
        仓库：\(item.repoSlug ?? item.title)
        简介：\(item.summary.isEmpty ? "无" : item.summary)
        语言：\(item.language ?? "未知")
        README 开头：
        \(String(readme.prefix(1_200)))
        """
    }

    private static let repoPrompt = """
    你在给一个技术 feed 写一句话摘要。用中文说清这个项目到底做了什么、给谁用。
    不超过 34 个字，一句话，结尾不加句号。不复述标语，不用「赋能/一站式/全新/让…更简单」这类空话。
    不超过两个专有名词，英文名保留原样。信息不足就回「看不清这个仓库具体做什么」。只输出那一句。
    """

    private static let releasePrompt = """
    你在给一个技术 feed 写一句话摘要。用中文说清这个版本改了什么，不超过 30 个字，一句话，结尾不加句号。
    只挑最要紧的一两条变化，别罗列。信息不足就回「看不清」。只输出那一句。
    """

    private struct Message: Encodable { let role: String; let content: String }
    private struct Body: Encodable {
        let model: String
        let temperature: Double
        let max_tokens: Int
        let messages: [Message]
    }
    private struct Reply: Decodable {
        struct Choice: Decodable { let message: Message }
        struct Message: Decodable { let content: String }
        let choices: [Choice]
    }

    private static func ask(key: String, system: String, user: String) async -> String? {
        guard let url = URL(string: "https://api.deepseek.com/chat/completions") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = Body(
            model: "deepseek-chat",
            temperature: 0.2,
            max_tokens: 90,
            messages: [Message(role: "system", content: system), Message(role: "user", content: user)]
        )
        guard let encoded = try? JSONEncoder().encode(body) else { return nil }
        request.httpBody = encoded
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let reply = try? JSONDecoder().decode(Reply.self, from: data)
        else { return nil }
        return reply.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 密钥

    /// 依次找：环境变量 → 本 App 存进钥匙串的 → pi 自己的 auth.json。
    /// 只是用来写一句话摘要，拿不到就退回原始简介，不影响 feed 本身。
    static var apiKey: String? {
        for name in ["OPENFEED_LLM_KEY", "DEEPSEEK_API_KEY"] {
            if let value = ProcessInfo.processInfo.environment[name], !value.isEmpty { return value }
        }
        if let value = Auth.keychainToken(service: "app.openfeed.deepseek",
                                          account: "apiKey"), !value.isEmpty {
            return value
        }
        return piKey
    }

    static var keySource: String {
        if ProcessInfo.processInfo.environment["OPENFEED_LLM_KEY"] != nil
            || ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"] != nil { return "环境变量" }
        if Auth.keychainToken(service: "app.openfeed.deepseek", account: "apiKey") != nil { return "钥匙串" }
        if piKey != nil { return "pi 的 DeepSeek 密钥" }
        return "没有密钥"
    }

    private static var piKey: String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/auth.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deepseek = object["deepseek"] as? [String: Any],
              let key = deepseek["key"] as? String, !key.isEmpty
        else { return nil }
        return key
    }
}

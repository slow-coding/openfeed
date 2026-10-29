import Foundation

/// 「我当下关注什么」——一份能看、能手改的 Markdown，放在 Application Support 里。
/// 它不只给人看：里面提到的线会在打分时加权重，改完立刻按新的排。
enum PreferencesDoc {
    static var fileURL: URL { Paths.root.appendingPathComponent("preferences.md") }

    /// 第一次运行时写下的模板：几行说明，不替你选兴趣。
    static var fallback: String {
        L.isEN ? fallbackEN : fallbackZH
    }

    private static let fallbackEN = """
    # What I am watching

    One line per thing you actually look for.

    Lines starting with ★ count as "what I want most right now"; plain - lines count as "also on the radar".

    Mention a lane by its name (the `lane` field in config.json) and that lane's weight goes up.
    To teach it more spellings, give the lane a word list under `laneKeywords` in config.json.
    The next fetch re-ranks after you edit this file.
    """

    private static let fallbackZH = """
    # 我在留意什么

    一行一条，写你每天真在翻的东西。

    ★ 开头的算「现在最想要的」，越靠前越重；没星的只算「也在看」。

    提到某条线的名字（config.json 里 queries 的 lane），那条线的权重就跟着涨。
    想让它认更多写法，就在 config.json 的 laneKeywords 里给那条线配一组词。
    改完这个文件，下一次刷新就按新的排。
    """

    static func load() -> String {
        if let text = try? String(contentsOf: fileURL, encoding: .utf8), !text.isEmpty { return text }
        save(fallback)
        return fallback
    }

    static func save(_ text: String) {
        try? FileManager.default.createDirectory(at: Paths.root, withIntermediateDirectories: true)
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        cached = nil
    }

    private static var cached: [String: Double]?

    /// 打分时问「这条线在偏好里有多重」。文件不常变，算一次挂着。
    static func boost(for lane: String) -> Double {
        if cached == nil { cached = boosts(load()) }
        return cached?[lane] ?? 0
    }

    /// 文档里提到的线。一条线被提到几次就算几次，最高那条归一成 0.55。
    /// 词从 config 的 laneKeywords 来；没配的线就只认线名本身。
    static func boosts(_ text: String = load()) -> [String: Double] {
        let config = FeedConfig.load()
        var table = config.laneKeywords
        for lane in Set(config.queries.map(\.lane)) where table[lane] == nil {
            table[lane] = [lane.lowercased()]
        }
        let lowered = text.lowercased()
        var hits: [String: Int] = [:]
        for (lane, words) in table {
            let count = words.reduce(0) { partial, word in
                partial + (lowered.components(separatedBy: word.lowercased()).count - 1)
            }
            if count > 0 { hits[lane] = count }
        }
        // 按「被提到最多的那条线」归一：文档里写得多的线才真的往上抬，
        // 每条都提一句的（模板就这样）不会把所有线一起抬。
        let maxHits = max(hits.values.max() ?? 1, 1)
        return hits.mapValues { 0.55 * Double($0) / Double(maxHits) }
    }
}

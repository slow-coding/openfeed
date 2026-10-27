import Foundation

/// 学到的偏好。只存一个权重表：key 是特征名，value 是可正可负的权重。
/// 拖一次就得到一对「A 该在 B 上面」的证据，按逻辑回归更一格；看过的条目给那条线一点点分。
struct Preferences: Codable {
    var weights: [String: Double] = [:]
    var pairs: Int = 0
    var clicks: Int = 0
    var updatedAt: Date = Date()

    static func load() -> Preferences {
        guard let data = try? Data(contentsOf: Paths.prefs),
              let prefs = try? JSONDecoder.openFeed.decode(Preferences.self, from: data)
        else { return Preferences() }
        return prefs
    }

    func save() {
        try? FileManager.default.createDirectory(at: Paths.root, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder.openFeed.encode(self) else { return }
        try? data.write(to: Paths.prefs, options: .atomic)
    }

    func weight(_ key: String) -> Double { weights[key] ?? 0 }

    /// 每拉一次都往 0 收一点：偏好会变，别让三个月前的一次拖拽定死今天。
    mutating func decay() {
        for (key, value) in weights {
            let next = value * 0.99
            weights[key] = abs(next) < 0.01 ? nil : next
        }
        updatedAt = Date()
    }

    mutating func learn(winner: FeedItem, loser: FeedItem) {
        let a = ValueModel.features(winner)
        let b = ValueModel.features(loser)
        var diff: [String: Double] = [:]
        for (key, value) in a { diff[key, default: 0] += value }
        for (key, value) in b { diff[key, default: 0] -= value }
        let norm = diff.values.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0.001 else { return }
        let margin = zip(diff.keys, diff.keys).reduce(0.0) { partial, pair in
            let key = pair.0
            return partial + (weights[key] ?? 0) * (diff[key] ?? 0) / norm
        }
        let p = 1 / (1 + exp(-margin))
        let step = 0.35 * (1 - p) / norm
        for (key, value) in diff {
            var next = (weights[key] ?? 0) + step * value
            next = min(1.6, max(-1.6, next))
            weights[key] = abs(next) < 0.01 ? nil : next
        }
        pairs += 1
        updatedAt = Date()
    }

    /// 打分：4~5 星给这条线加分，1~2 星扣分，3 星算是「一般」不动。
    mutating func noteRating(_ item: FeedItem, stars: Int) {
        let delta = (Double(stars) - 3) * 0.05
        guard delta != 0 else { return }
        let key = "lane:\(item.lane)"
        var next = (weights[key] ?? 0) + delta
        next = min(1.6, max(-1.6, next))
        weights[key] = next
        updatedAt = Date()
    }

    /// 点开一条 = 弱信号，比拖拽轻一个量级。
    mutating func noteClick(_ item: FeedItem) {
        let key = "lane:\(item.lane)"
        var next = (weights[key] ?? 0) + 0.04
        next = min(1.6, max(-1.6, next))
        weights[key] = next
        if item.isExploration { next = (weights["explore"] ?? 0) + 0.02; weights["explore"] = next }
        clicks += 1
        updatedAt = Date()
    }

    /// 探索线被反复往上拖 / 反复点，就当成本来的兴趣线。
    func isPromoted(lane: String) -> Bool { weight("lane:\(lane)") >= 0.5 }
}

enum ValueModel {
    /// 特征都是「已经乘好尺度」的贡献值，最后直接相加。
    static func features(_ item: FeedItem, now: Date = Date()) -> [String: Double] {
        var f: [String: Double] = [:]
        f["kind:\(item.kind.rawValue)"] = 1
        f["lane:\(item.lane)"] = 1
        if item.isExploration { f["explore"] = 1 }

        switch item.kind {
        case .repo:
            f["stars"] = log10(1 + Double(item.stars ?? 0))
            if let delta = item.starsDelta, delta > 0 {
                f["delta"] = log10(1 + Double(delta))
            }
            let days = max(0, now.timeIntervalSince(item.createdAt) / 86_400)
            f["fresh"] = max(0, 30 - days) / 30
        case .release:
            // 版本本身也是新闻，但它不该盖过今天新出现的东西：最多加 13 分。
            let hours = max(0, now.timeIntervalSince(item.createdAt) / 3_600)
            f["fresh"] = max(0, 72 - hours) / 72 * 0.5
        case .story:
            f["points"] = log10(1 + Double(item.stars ?? 0)) / 2
            let hours = max(0, now.timeIntervalSince(item.createdAt) / 3_600)
            f["fresh"] = max(0, 48 - hours) / 48 * 0.4
        }
        return f
    }

    /// 每个特征的基础权重；学习到的偏好叠加在基础权重上（wlane 的基线是 0）。
    private static let base: [String: Double] = [
        "kind:repo": 4, "kind:release": 12, "kind:story": 6,
        "stars": 6, "delta": 9, "fresh": 26, "points": 16,
        "lane:": 0, "explore": 0
    ]

    static func score(_ item: FeedItem, prefs: Preferences, now: Date = Date()) -> (value: Double, reasons: [String]) {
        let f = features(item, now: now)
        var total = 0.0
        var parts: [(Double, String)] = []

        for (key, amount) in f {
            let baseWeight = base[key] ?? 0
            let learned = prefs.weight(key)
            let contribution = amount * (baseWeight + learned * 14)
            total += contribution
            if contribution > 0.3 { parts.append((contribution, reason(key, item: item, amount: amount))) }
        }

        // 偏好文档里提到这条线，就一直给它一点倾斜（改文档立刻生效）
        let docBoost = PreferencesDoc.boost(for: item.lane)
        if docBoost > 0 {
            total += 12 * docBoost
            parts.append((12 * docBoost, "你把它写进了当下偏好"))
        }

        // 你打的分是明确信号：5 星 +8，1 星 -8
        if item.rating > 0 {
            let lift = Double(item.rating - 3) * 4
            total += lift
            if lift > 0 { parts.append((lift, "你打了 \(item.rating) 星")) }
        }

        if item.isExploration, !prefs.isPromoted(lane: item.lane) {
            total *= 0.82
            parts.append((0, "探索项"))
        }

        let top = parts.sorted { $0.0 > $1.0 }.prefix(2).map { $0.1 }
        return (total, top)
    }

    private static func reason(_ key: String, item: FeedItem, amount: Double) -> String {
        switch key {
        case "stars":
            return "\((item.stars ?? 0).starText) 星"
        case "delta":
            return "这轮涨 \((item.starsDelta ?? 0).starText) 星"
        case "fresh":
            switch item.kind {
            case .repo: return "新仓库，\(item.createdAt.agoText)建的"
            case .release: return "\(item.createdAt.agoText)发布"
            case .story: return "\(item.createdAt.agoText)"
            }
        case "points":
            return "\(item.stars ?? 0) 分"
        case let lane where lane.hasPrefix("lane:"):
            return "你在「\(item.lane)」线给它加分了"
        case "explore":
            return "探索项，你拖过这类"
        default:
            return ""
        }
    }
}

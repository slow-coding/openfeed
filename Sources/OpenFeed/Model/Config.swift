import Foundation

/// 一条 GitHub 搜索。`{since}` 换成窗口起始日，`{recent}` 换成最近 7 天。
struct QueryConfig: Codable {
    var lane: String
    var q: String
    var sort: String = "stars"
    var days: Int = 45
    var limit: Int = 15
    /// 没登录取不到 30 次/分的额度，这些「看还在涨」的查询就先不跑
    var needsAuth: Bool = false
    /// 命中词：仓库的名字 / 简介 / 话题里至少有一个才留下。
    /// topic 是自我声明的，不设这道闸，「知识图谱」这种词会把教辅题库也拉进来。
    var must: [String] = []

    init(lane: String, q: String, sort: String = "stars", days: Int = 45,
         limit: Int = 15, needsAuth: Bool = false, must: [String] = []) {
        self.lane = lane; self.q = q; self.sort = sort; self.days = days
        self.limit = limit; self.needsAuth = needsAuth; self.must = must
    }

    // 手写解码：config.json 少写一个字段不该让整份配置失效。
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        lane = try box.decode(String.self, forKey: .lane)
        q = try box.decode(String.self, forKey: .q)
        sort = try box.decodeIfPresent(String.self, forKey: .sort) ?? "stars"
        days = try box.decodeIfPresent(Int.self, forKey: .days) ?? 45
        limit = try box.decodeIfPresent(Int.self, forKey: .limit) ?? 15
        needsAuth = try box.decodeIfPresent(Bool.self, forKey: .needsAuth) ?? false
        must = try box.decodeIfPresent([String].self, forKey: .must) ?? []
    }
}

struct FeedConfig: Codable {
    var hour: Int = 9
    var queries: [QueryConfig] = FeedConfig.defaultQueries
    var releases: [String] = FeedConfig.defaultReleases
    var stories: [String] = FeedConfig.defaultStories
    var allowImages: Bool = true
    /// 探索线：不在你写下的兴趣里、混进来供发现的线。列在这里的线压一档，标成「探索」。
    var exploreLanes: [String] = FeedConfig.defaultExploreLanes
    /// 某条线的一组词：preferences.md 提到这些词就算提到这条线。不配就只认线名。
    var laneKeywords: [String: [String]] = [:]
    /// 选填：任何兼容 OpenAI 的 /chat/completions 端点。空着就不调模型，一勺话退回仓库原文简介。
    var llmBaseURL: String = ""
    var llmModel: String = ""

    /// 开箱就带两条探索线：你没写进 preferences.md 的那类，压一档混在流里。
    static let defaultExploreLanes = ["本地优先", "可视化"]

    init() {}

    // 手写解码：config.json 少写一个字段不该让整份配置失效（旧版写下的文件里没有后两个键）。
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        hour = try box.decodeIfPresent(Int.self, forKey: .hour) ?? 9
        queries = try box.decodeIfPresent([QueryConfig].self, forKey: .queries) ?? Self.defaultQueries
        releases = try box.decodeIfPresent([String].self, forKey: .releases) ?? Self.defaultReleases
        stories = try box.decodeIfPresent([String].self, forKey: .stories) ?? Self.defaultStories
        allowImages = try box.decodeIfPresent(Bool.self, forKey: .allowImages) ?? true
        exploreLanes = try box.decodeIfPresent([String].self, forKey: .exploreLanes)
            ?? Self.defaultExploreLanes
        laneKeywords = try box.decodeIfPresent([String: [String]].self, forKey: .laneKeywords) ?? [:]
        llmBaseURL = try box.decodeIfPresent(String.self, forKey: .llmBaseURL) ?? ""
        llmModel = try box.decodeIfPresent(String.self, forKey: .llmModel) ?? ""
    }

    /// 开箱的几条线，随便改：改成你每天真在找的东西，面板才像你说的那样。
    static let defaultQueries: [QueryConfig] = [
        // 新出现的：最近 45 天建仓，按星排。
        .init(lane: "智能体", q: "topic:ai-agents stars:>200 created:>{since}"),
        .init(lane: "智能体", q: "topic:llm-agent stars:>100 created:>{since}"),
        .init(lane: "编程助手", q: "topic:coding-assistant stars:>200 created:>{since}"),
        .init(lane: "开发工具", q: "\"developer tools\" in:description stars:>500 created:>{since}",
              limit: 10),
        // 老的但还在涨：不按创建日筛，靠本地记下的星数差。
        .init(lane: "智能体", q: "topic:ai-agents stars:>2000 pushed:>{recent}", sort: "updated",
              limit: 20, needsAuth: true),
        // 探索线：你没写进 preferences.md 的那几条，压一档混在流里。
        .init(lane: "本地优先", q: "topic:local-first stars:>300 created:>{since}", days: 60,
              limit: 8, must: ["local-first", "offline", "sync", "crdt", "peer"]),
        .init(lane: "可视化", q: "topic:data-visualization stars:>250 created:>{since}", days: 60,
              limit: 10, must: ["chart", "dashboard", "visual", "plot", "graph", "canvas"]),
    ]

    /// 这些有版本就够了，不需要它天天上新闻。release 走 atom，不占 API 额度。
    static let defaultReleases: [String] = [
        "modelcontextprotocol/servers",
        "vercel/ai",
        "openai/codex",
        "shadcn-ui/ui",
        "mrdoob/three.js"
    ]

    static let defaultStories: [String] = [
        "AI coding agent",
        "local-first software"
    ]

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("OpenFeed", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("config.json") }

    static func load() -> FeedConfig {
        guard let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(FeedConfig.self, from: data)
        else {
            let fresh = FeedConfig()
            fresh.save()
            return fresh
        }
        return config
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(self) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}

/// 状态在 Application Support；能重新生成的图在 Caches（删了不心疼，也方便一键清）。
enum Paths {
    static var root: URL { FeedConfig.directory }
    static var feed: URL { root.appendingPathComponent("feed.json") }
    static var seen: URL { root.appendingPathComponent("seen.json") }
    static var prefs: URL { root.appendingPathComponent("prefs.json") }
    static var summaries: URL { root.appendingPathComponent("summaries.json") }
    static var ratings: URL { root.appendingPathComponent("ratings.json") }
    static var readmes: URL { cache.appendingPathComponent("readmes", isDirectory: true) }
    static var cache: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("OpenFeed", isDirectory: true)
    }
    static var images: URL { cache.appendingPathComponent("images", isDirectory: true) }
    static var avatars: URL { cache.appendingPathComponent("avatars", isDirectory: true) }
    static var imageManifest: URL { cache.appendingPathComponent("images.json") }
    static func ensure() {
        for directory in [root, cache, images, avatars, readmes] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

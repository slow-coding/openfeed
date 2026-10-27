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

    static let defaultQueries: [QueryConfig] = [
        // 新出现的：45 天内建仓，按星排。这是「feed 有新东西」的主力。
        .init(lane: "上下文记忆", q: "topic:agent-memory stars:>150 created:>{since}"),
        .init(lane: "上下文记忆", q: "\"context engineering\" in:name,description,readme stars:>120 created:>{since}"),
        .init(lane: "上下文记忆", q: "topic:llm-memory stars:>80 created:>{since}"),
        .init(lane: "上下文记忆", q: "topic:context-engineering stars:>100 created:>{since}"),
        .init(lane: "记忆图谱", q: "\"graph rag\" in:name,description stars:>150 created:>{since}",
              must: ["llm", "rag", "agent", "memory", "embedding", "retrieval", "智能体"]),
        .init(lane: "记忆图谱", q: "\"memory graph\" in:name,description stars:>20 created:>{since}",
              must: ["llm", "rag", "agent", "memory", "embedding", "retrieval", "智能体"]),
        .init(lane: "记忆图谱", q: "topic:graphrag stars:>20 created:>{since}",
              must: ["llm", "rag", "agent", "memory", "embedding", "retrieval", "智能体"]),
        .init(lane: "Agent", q: "topic:multi-agent stars:>250 created:>{since}"),
        .init(lane: "Agent", q: "topic:agent-orchestration stars:>120 created:>{since}"),
        .init(lane: "编程智能体", q: "topic:coding-agent stars:>300 created:>{since}"),
        .init(lane: "编程智能体", q: "\"vibe coding\" in:name,description stars:>250 created:>{since}"),
        .init(lane: "生成式界面", q: "topic:generative-ui stars:>80 created:>{since}"),
        .init(lane: "动效视觉", q: "topic:webgl stars:>300 created:>{since}", days: 90,
              must: ["webgl", "shader", "three", "graphics", "canvas"]),
        .init(lane: "动效视觉", q: "topic:animation stars:>250 created:>{since}", days: 90,
              must: ["animation", "motion", "css", "svg", "transition"]),
        // 下面几条是「我没提过、但你可能想要」的探索线。它们不按你的兴趣线出，混在流里；
        // 你把它们拖上去或者点开，那条线的权重就涨，涨到 0.5 以上就不再当探索项。
        .init(lane: "本地优先", q: "topic:local-first stars:>300 created:>{since}", days: 60,
              limit: 8, must: ["local-first", "offline", "sync", "crdt", "peer"]),
        .init(lane: "端侧模型", q: "topic:on-device-ml stars:>200 created:>{since}", days: 60,
              limit: 8, must: ["on-device", "mobile", "local", "coreml", "mlx", "edge"]),
        .init(lane: "评测与观测", q: "topic:llm-evaluation stars:>150 created:>{since}", days: 60,
              limit: 8, must: ["eval", "benchmark", "observability", "trace", "guardrail"]),
        .init(lane: "设计工程", q: "topic:design-engineering stars:>200 created:>{since}", days: 60,
              limit: 8, must: ["design", "ui", "component", "typography", "interface"]),
        // 老的但还在涨：不按创建日筛，靠本地星数差（见 Scoring）
        .init(lane: "上下文记忆", q: "topic:agent-memory stars:>1000 pushed:>{recent}", sort: "updated",
              limit: 20, needsAuth: true,
              must: ["memory", "context", "agent", "llm", "记忆"]),
        .init(lane: "编程智能体", q: "topic:coding-agent stars:>2000 pushed:>{recent}", sort: "updated", limit: 20, needsAuth: true),
        .init(lane: "生成式界面", q: "topic:generative-ui stars:>300 pushed:>{recent}", sort: "updated", limit: 20, needsAuth: true),
        .init(lane: "记忆图谱", q: "topic:knowledge-graph stars:>1500 pushed:>{recent}", sort: "updated",
              limit: 20, needsAuth: true,
              must: ["memory", "rag", "llm", "agent", "ontology", "embedding"]),
    ]

    /// 这些有版本就够了，不需要它天天上新闻。release 走 atom，不占 API 额度。
    static let defaultReleases: [String] = [
        "modelcontextprotocol/servers",
        "modelcontextprotocol/python-sdk",
        "langchain-ai/langgraph",
        "crewAIInc/crewAI",
        "microsoft/autogen",
        "agno-agi/agno",
        "mem0ai/mem0",
        "getzep/graphiti",
        "letta-ai/letta",
        "microsoft/graphrag",
        "shadcn-ui/ui",
        "CopilotKit/CopilotKit",
        "vercel/ai",
        "All-Hands-AI/OpenHands",
        "openai/codex",
        "google-gemini/gemini-cli",
        "danielmiessler/fabric",
        "modelcontextprotocol/inspector",
        "motiondivision/motion",
        "mrdoob/three.js"
    ]

    static let defaultStories: [String] = [
        "agent memory",
        "context engineering",
        "AI coding agent",
        "generative UI"
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

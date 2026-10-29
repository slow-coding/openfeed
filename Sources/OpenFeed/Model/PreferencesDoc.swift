import Foundation

/// 「我当下关注什么」——一份能看、能手改的 Markdown，放在 Application Support 里。
/// 它不只给人看：里面提到的线会在打分时加权重，改完立刻按新的排。
enum PreferencesDoc {
    static var fileURL: URL { Paths.root.appendingPathComponent("preferences.md") }

    static let fallback = """
    # 我当下关注的（2026-10-29）

    ★ vibe coding 出产物（现在最重）：一句话换一个能看能用的东西——单页 HTML、图表、幻灯片、报告、海报、短片。
    ★ 出产物的技能包：agent skills / claude skills 里把产物做好看的那批（页面、UI、logo、分镜、宣传片）。
    ★ 视觉与动效：动效、动画、交互动效、转场，能直接拿去看的产物。
    ★ 图表与可视化：仪表盘、时间轴、拓扑、关系图、桑基图、热力图。
    ★ 流程图与管线图：泳道、管路、决策路径，能画给人看的。
    ★ 3D 与 WebGL：three.js、r3f、shader、粒子，能在浏览器里动的。
    - 生成式界面：UI 由模型现场长出来（generative UI、artifact）。
    - 个人上下文的蒸馏：把讲过、写过的压成能用的记忆，而不是聊天记录检索。
    - 上下文记忆制图：知识图谱、memory graph、graph rag，看得见关系的那种。
    - Agent 的编排与图谱：多智能体怎么分工、怎么串、怎么在图上读懂。
    - 端侧与本地优先：数据留在本机，离线也能用。
    - 工具的品味：宁可少功能，也不要丑和慢。

    ★ 开头的几条是现在最想要的；改这份文件，排序跟着变。
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

    /// 文档里提到的线。一条线被提到几次就算几次，单条线封顶 0.6。
    static func boosts(_ text: String = load()) -> [String: Double] {
        let lowered = text.lowercased()
        var hits: [String: Int] = [:]
        for (lane, words) in keywords {
            let count = words.reduce(0) { partial, word in
                partial + (lowered.components(separatedBy: word).count - 1)
            }
            if count > 0 { hits[lane] = count }
        }
        // 按「被提到最多的那条线」归一：文档里写得多的线才真的往上抬，
        // 每条都提一句的（默认文档就这样）不会把所有线一起抬。
        let maxHits = max(hits.values.max() ?? 1, 1)
        return hits.mapValues { 0.55 * Double($0) / Double(maxHits) }
    }

    private static let keywords: [String: [String]] = [
        "动效视觉": ["动效", "动画", "animation", "motion", "3d", "webgl", "交互"],
        "可视化": ["可视化", "图表", "chart", "visualization", "仪表盘", "拓扑", "关系图", "桑基", "热力"],
        "生成式界面": ["生成式界面", "generative ui", "artifact", "生成式"],
        "上下文记忆": ["上下文", "记忆", "memory", "context"],
        "记忆图谱": ["图谱", "graph", "知识图谱"],
        "Agent": ["agent", "智能体", "多智能体"],
        "编程智能体": ["编程智能体", "coding agent", "改代码"],
        "vibe coding": ["vibe coding", "vibe", "出产物", "产物"],
        "本地优先": ["本地优先", "本地", "离线", "端侧", "local-first"],
        "评测与观测": ["评测", "eval", "观测", "trace"]
    ]
}

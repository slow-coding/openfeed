import Foundation

/// 一条 feed。三种东西混在一条流里：新仓库 / 关注项目的版本 / 论坛帖子。
enum FeedKind: String, Codable, CaseIterable {
    case repo
    case release
    case story

    var label: String {
        switch self {
        case .repo: return "仓库"
        case .release: return "版本"
        case .story: return "讨论"
        }
    }
}

struct FeedItem: Codable, Identifiable, Hashable {
    var id: String
    var kind: FeedKind
    /// 仓库名 / 版本号 / 帖子标题
    var title: String
    /// owner/name / 项目名 / 站点
    var subtitle: String
    var summary: String
    var url: URL
    var imageURL: URL?
    /// OG 卡片被限流（429）时用头像顶上
    var avatarURL: URL?
    /// GitHub 星数（只有仓库有）
    var stars: Int?
    var language: String?
    /// 上次拉取之后涨了多少星（本地算的，第一次拉取时是 nil）
    var starsDelta: Int?
    var createdAt: Date
    /// 第一次被拉进 feed 的时间，决定它落在哪一天那一节
    var foundAt: Date
    var score: Double
    /// 发现它的那条兴趣线
    var lane: String
    var visitedAt: Date?
    var muted: Bool = false

    var isRepo: Bool { kind == .repo }
    var isNewToday: Bool { Calendar.current.isDateInToday(foundAt) }
}

struct FeedSnapshot: Codable {
    var generatedAt: Date
    var items: [FeedItem]
    var lastSuccessAt: Date?
    /// 每个查询上次拉回来几条，出问题时能看出是哪一条挂了
    var report: [String] = []
}

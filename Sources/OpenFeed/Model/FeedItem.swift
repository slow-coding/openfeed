import Foundation

extension Notification.Name {
    /// 某条的一句话摘要算好了
    static let openFeedCoreLine = Notification.Name("openfeed.coreline")
}

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
    /// README 里那张主图（可能是仓库内的相对路径，存原样，取的时候再解析）
    var keyImagePath: String?
    var stars: Int?
    var language: String?
    var starsDelta: Int?
    var createdAt: Date
    var foundAt: Date
    var lane: String
    var visitedAt: Date?
    /// 不在你的兴趣线里、我挑进来的探索项
    var isExploration: Bool = false
    /// 价值分与理由，每次排序重算
    var value: Double = 0
    var reasons: [String] = []
    /// 「它到底做了什么」那一句话
    var coreLine: String?
    /// 你打的分，1~5，0 = 没打
    var rating: Int = 0

    var isRepo: Bool { kind == .repo }
    var isNewToday: Bool { Calendar.current.isDateInToday(foundAt) }
    /// 复制出去的那一小块：链接 + 一句话，粘到聊天里就能看。
    var copyText: String {
        let line = (coreLine ?? summary).trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .repo:
            return line.isEmpty ? "\(title)\n\(url.absoluteString)"
                                : "\(title) — \(line)\n\(url.absoluteString)"
        case .release:
            return line.isEmpty ? "\(subtitle) \(title)\n\(url.absoluteString)"
                                : "\(subtitle) \(title) — \(line)\n\(url.absoluteString)"
        case .story:
            return "\(title)\n\(url.absoluteString)"
        }
    }

    /// releases 的 subtitle 就是 owner/repo
    var repoSlug: String? {
        switch kind {
        case .repo: return subtitle + "/" + title
        case .release: return subtitle
        case .story: return nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, subtitle, summary, url, imageURL, avatarURL, keyImagePath
        case stars, language, starsDelta, createdAt, foundAt, lane, visitedAt
        case isExploration, value, reasons, coreLine, rating
    }

    init(id: String, kind: FeedKind, title: String, subtitle: String, summary: String, url: URL,
         imageURL: URL?, avatarURL: URL?, keyImagePath: String? = nil, stars: Int?, language: String?,
         starsDelta: Int?, createdAt: Date, foundAt: Date, lane: String, visitedAt: Date? = nil,
         isExploration: Bool = false, value: Double = 0, reasons: [String] = [],
         coreLine: String? = nil, rating: Int = 0) {
        self.id = id; self.kind = kind; self.title = title; self.subtitle = subtitle
        self.summary = summary; self.url = url; self.imageURL = imageURL; self.avatarURL = avatarURL
        self.keyImagePath = keyImagePath; self.stars = stars; self.language = language
        self.starsDelta = starsDelta; self.createdAt = createdAt; self.foundAt = foundAt
        self.lane = lane; self.visitedAt = visitedAt; self.isExploration = isExploration
        self.value = value; self.reasons = reasons; self.coreLine = coreLine
    }

    // 老快照里没有后加的字段，缺了就取默认值，别让整份数据解不出来。
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(String.self, forKey: .id)
        kind = try box.decode(FeedKind.self, forKey: .kind)
        title = try box.decode(String.self, forKey: .title)
        subtitle = try box.decode(String.self, forKey: .subtitle)
        summary = try box.decode(String.self, forKey: .summary)
        url = try box.decode(URL.self, forKey: .url)
        imageURL = try box.decodeIfPresent(URL.self, forKey: .imageURL)
        avatarURL = try box.decodeIfPresent(URL.self, forKey: .avatarURL)
        keyImagePath = try box.decodeIfPresent(String.self, forKey: .keyImagePath)
        stars = try box.decodeIfPresent(Int.self, forKey: .stars)
        language = try box.decodeIfPresent(String.self, forKey: .language)
        starsDelta = try box.decodeIfPresent(Int.self, forKey: .starsDelta)
        createdAt = try box.decode(Date.self, forKey: .createdAt)
        foundAt = try box.decode(Date.self, forKey: .foundAt)
        lane = try box.decode(String.self, forKey: .lane)
        visitedAt = try box.decodeIfPresent(Date.self, forKey: .visitedAt)
        isExploration = try box.decodeIfPresent(Bool.self, forKey: .isExploration) ?? false
        value = try box.decodeIfPresent(Double.self, forKey: .value) ?? 0
        reasons = try box.decodeIfPresent([String].self, forKey: .reasons) ?? []
        coreLine = try box.decodeIfPresent(String.self, forKey: .coreLine)
        rating = try box.decodeIfPresent(Int.self, forKey: .rating) ?? 0
    }
}

struct FeedSnapshot: Codable {
    var generatedAt: Date
    var items: [FeedItem]
    var lastSuccessAt: Date?
    /// 每个查询上次拉回来几条，出问题时能看出是哪一条挂了
    var report: [String] = []
    /// 手动拖过之后，那一天按这个顺序摆（day key → item ids）
    var order: [String: [String]] = [:]
    /// 上次清缓存的时间与清掉多少
    var lastCacheSweep: Date?
    var lastCacheSweepCount: Int = 0

    init(generatedAt: Date, items: [FeedItem], lastSuccessAt: Date?, report: [String] = [],
         order: [String: [String]] = [:], lastCacheSweep: Date? = nil, lastCacheSweepCount: Int = 0) {
        self.generatedAt = generatedAt; self.items = items; self.lastSuccessAt = lastSuccessAt
        self.report = report; self.order = order
        self.lastCacheSweep = lastCacheSweep; self.lastCacheSweepCount = lastCacheSweepCount
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try box.decode(Date.self, forKey: .generatedAt)
        items = try box.decode([FeedItem].self, forKey: .items)
        lastSuccessAt = try box.decodeIfPresent(Date.self, forKey: .lastSuccessAt)
        report = try box.decodeIfPresent([String].self, forKey: .report) ?? []
        order = try box.decodeIfPresent([String: [String]].self, forKey: .order) ?? [:]
        lastCacheSweep = try box.decodeIfPresent(Date.self, forKey: .lastCacheSweep)
        lastCacheSweepCount = try box.decodeIfPresent(Int.self, forKey: .lastCacheSweepCount) ?? 0
    }
}

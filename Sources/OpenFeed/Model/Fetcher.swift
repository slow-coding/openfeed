import Foundation

struct RepoHit {
    let fullName: String
    let description: String
    let language: String?
    let stars: Int
    let url: URL
    let imageURL: URL?
    let avatarURL: URL?
    let createdAt: Date
    let pushedAt: Date?
    let topics: [String]
    let lane: String
    /// 「还在涨」那一类查询：只在已经跟踪过的项目上用来算涨星，不直接往 feed 里塞
    let velocity: Bool
}

struct ReleaseHit {
    let repo: String
    let title: String
    let url: URL
    let notes: String
    let publishedAt: Date
}

struct StoryHit {
    let title: String
    let url: URL
    let points: Int
    let comments: Int
    let publishedAt: Date
    let domain: String
}

struct FetchOutcome {
    var repos: [RepoHit] = []
    var releases: [ReleaseHit] = []
    var stories: [StoryHit] = []
    var report: [String] = []
    var authorized: Bool = false
}

/// 三个上游：GitHub 搜索（要额度）、GitHub release atom（不要额度）、HN Algolia（不要额度）。
struct Fetcher {
    private let session: URLSession
    private let token: String?

    init(token: String? = Auth.token) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = ["User-Agent": "OpenFeed/1.0"]
        self.session = URLSession(configuration: config)
        self.token = token
    }

    var authorized: Bool { token != nil }

    // MARK: - GitHub 搜索

    func search(_ query: QueryConfig, now: Date) async throws -> [RepoHit] {
        let since = Self.day(now.addingTimeInterval(-Double(query.days) * 86_400))
        let recent = Self.day(now.addingTimeInterval(-7 * 86_400))
        let text = query.q
            .replacingOccurrences(of: "{since}", with: since)
            .replacingOccurrences(of: "{recent}", with: recent)
        guard var components = URLComponents(string: "https://api.github.com/search/repositories") else {
            return []
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "sort", value: query.sort),
            URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "per_page", value: String(min(query.limit, 50)))
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return [] }
        if http.statusCode != 200 {
            let message = (try? JSONDecoder().decode(GitHubError.self, from: data))?.message ?? "HTTP \(http.statusCode)"
            if http.statusCode == 403 || http.statusCode == 429 {
                // 额度是按分钟滚的，响应头里有准确的恢复时刻
                let reset = http.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init)
                throw FetchError.rateLimited(message, reset: reset.map { Date(timeIntervalSince1970: $0) })
            }
            throw FetchError.search(message)
        }
        let decoded = try JSONDecoder.openFeed.decode(GitHubSearch.self, from: data)
        let hits = decoded.items.map { repo in
            RepoHit(
                fullName: repo.fullName,
                description: repo.description ?? "",
                language: repo.language,
                stars: repo.stargazersCount,
                url: repo.htmlURL,
                imageURL: URL(string: "https://opengraph.githubassets.com/1/\(repo.fullName)"),
                avatarURL: URL(string: repo.owner.avatarURL.absoluteString + "&s=80"),
                createdAt: repo.createdAt,
                pushedAt: repo.pushedAt,
                topics: repo.topics ?? [],
                lane: query.lane,
                velocity: query.sort == "updated"
            )
        }
        guard !query.must.isEmpty else { return hits }
        let anchors = query.must.map { $0.lowercased() }
        return hits.filter { hit in
            let text = (hit.fullName + " " + hit.description + " " + hit.topics.joined(separator: " ")).lowercased()
            return anchors.contains { text.contains($0) }
        }
    }

    // MARK: - Releases

    /// 走 REST 不走 releases.atom：这台机器上 URLSession 连 github.com 会挂满 60 秒超时，
    /// api.github.com 却是通的（curl 两边都通，问题在系统的网络栈那一侧）。
    /// 顺带拿到的是结构化字段，比解析 atom 干净。
    func releases(for repo: String, since: Date) async -> [ReleaseHit] {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=6") else { return [] }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let releases = try? JSONDecoder.openFeed.decode([GitHubRelease].self, from: data)
        else { return [] }
        return releases
            .filter { $0.publishedAt >= since }
            .prefix(1)
            .compactMap { release in
                guard let url = release.htmlURL else { return nil }
                let title = release.name?.isEmpty == false ? release.name! : release.tagName
                var notes = Self.plainText(release.body ?? "")
                // 正文常常从版本号开头，标题里已经有了，删掉免得两行读起来一样。
                notes = notes.replacingOccurrences(
                    of: "^v?\\d+(\\.\\d+)*(\\s*\\(\\d{4}-\\d{2}-\\d{2}\\))?\\s*",
                    with: "", options: .regularExpression
                )
                return ReleaseHit(
                    repo: repo,
                    title: title,
                    url: url,
                    notes: notes,
                    publishedAt: release.publishedAt
                )
            }
    }

    // MARK: - Hacker News

    func stories(query: String, since: Date, minimumPoints: Int = 40) async -> [StoryHit] {
        var components = URLComponents(string: "https://hn.algolia.com/api/v1/search")
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "tags", value: "story"),
            URLQueryItem(name: "hitsPerPage", value: "8"),
            URLQueryItem(
                name: "numericFilters",
                value: "created_at_i>\(Int(since.timeIntervalSince1970)),points>\(minimumPoints)"
            )
        ]
        guard let url = components?.url else { return [] }
        guard let (data, _) = try? await session.data(from: url) else { return [] }
        guard let decoded = try? JSONDecoder.openFeed.decode(HNResponse.self, from: data) else { return [] }
        return decoded.hits.compactMap { hit in
            guard let title = hit.title, let link = hit.url, let url = URL(string: link) else { return nil }
            return StoryHit(
                title: title,
                url: url,
                points: hit.points ?? 0,
                comments: hit.numComments ?? 0,
                publishedAt: Date(timeIntervalSince1970: TimeInterval(hit.createdAtI ?? 0)),
                domain: URL(string: link)?.host?.replacingOccurrences(of: "www.", with: "") ?? ""
            )
        }
    }

    // MARK: - 小工具

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// release notes 是 Markdown 里混 HTML，抹成一句能读的话。
    static func plainText(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "</p>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "#{1,6}\\s*", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "[*_`>]", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        for (entity, plain) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                                ("&#39;", "'"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: plain)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum FetchError: LocalizedError {
    case search(String)
    case rateLimited(String, reset: Date?)

    var errorDescription: String? {
        switch self {
        case .search(let message), .rateLimited(let message, _): return message
        }
    }

    var isRateLimit: Bool {
        if case .rateLimited = self { return true }
        return false
    }
}

private struct GitHubError: Decodable {
    let message: String
}

private struct GitHubSearch: Decodable {
    let items: [GitHubRepo]
}

private struct GitHubRepo: Decodable {
    private enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case htmlURL = "html_url"
        case description
        case stargazersCount = "stargazers_count"
        case language
        case topics
        case createdAt = "created_at"
        case pushedAt = "pushed_at"
        case owner
    }

    let fullName: String
    let htmlURL: URL
    let description: String?
    let stargazersCount: Int
    let language: String?
    let topics: [String]?
    let createdAt: Date
    let pushedAt: Date?
    let owner: GitHubOwner

    struct GitHubOwner: Decodable {
        private enum CodingKeys: String, CodingKey {
            case avatarURL = "avatar_url"
        }
        let avatarURL: URL
    }
}

private struct GitHubRelease: Decodable {
    private enum CodingKeys: String, CodingKey {
        case name
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body
        case publishedAt = "published_at"
    }

    let name: String?
    let tagName: String
    let htmlURL: URL?
    let body: String?
    let publishedAt: Date
}

private struct HNResponse: Decodable {
    let hits: [HNHit]
}

private struct HNHit: Decodable {
    private enum CodingKeys: String, CodingKey {
        case title, url, points
        case numComments = "num_comments"
        case createdAtI = "created_at_i"
    }

    let title: String?
    let url: String?
    let points: Int?
    let numComments: Int?
    let createdAtI: Int?
}

extension JSONDecoder {
    static var openFeed: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

import Foundation

/// 见过的仓库。星数每天记一次，第二天就能算出「这一周涨了多少」。
struct SeenRepo: Codable {
    var stars: Int
    var firstSeen: Date
    var lastSeen: Date
}

struct SeenIndex: Codable {
    var repos: [String: SeenRepo] = [:]
    var muted: [String] = []

    var mutedSet: Set<String> { Set(muted) }

    static func load() -> SeenIndex {
        guard let data = try? Data(contentsOf: Paths.seen),
              let index = try? JSONDecoder.openFeed.decode(SeenIndex.self, from: data)
        else { return SeenIndex() }
        return index
    }

    func save() {
        guard let data = try? JSONEncoder.openFeed.encode(self) else { return }
        try? data.write(to: Paths.seen, options: .atomic)
    }
}

enum Merge {
    /// 一天的窗口：新东西进来，老东西不重复刷屏。
    static let keepDays = 10

    static func run(repos: [RepoHit], releases: [ReleaseHit], stories: [StoryHit],
                    existing: [FeedItem], seen: SeenIndex, now: Date)
        -> (items: [FeedItem], seen: SeenIndex, added: Int) {
        var index = seen
        let muted = seen.mutedSet
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        var added = 0

        // 同一条仓库可能被好几条查询命中：留第一次出现的那条兴趣线，星数取最大值。
        var uniqueRepos: [String: RepoHit] = [:]
        for hit in repos {
            let key = hit.fullName.lowercased()
            if let old = uniqueRepos[key], old.stars >= hit.stars { continue }
            uniqueRepos[key] = hit
        }

        for (key, hit) in uniqueRepos {
            guard !muted.contains(key) else { continue }
            // 「awesome 列表」不算新东西：搜 topic 时它们永远排在前面，一进来就把 feed 淹了。
            guard !Self.isList(key, description: hit.description) else { continue }
            let previous = index.repos[key]
            let delta = previous.map { hit.stars - $0.stars } ?? nil
            let isFirstSighting = previous == nil

            let existingItem = byID["repo:\(key)"]
            let climbed = (delta ?? 0) >= 300

            if isFirstSighting {
                // 「还在涨」那几条查询一把能拉回几百个老项目：第一次只记账，不上版面。
                // 从第二天起它们有了星数差，真涨起来的才冒头。
                if hit.velocity { continue }
            } else if let existingItem {
                // 见过的项目不再进今天的流，只有这几天又涨了不少才重新冒上来。
                let days = now.timeIntervalSince(existingItem.foundAt) / 86_400
                if !(climbed && days >= 3) { continue }
            } else {
                // 上一轮被 60 条上限挤掉的：只有涨星才给它第二次机会。
                if !climbed { continue }
            }

            index.repos[key] = SeenRepo(
                stars: hit.stars,
                firstSeen: previous?.firstSeen ?? now,
                lastSeen: now
            )

            let score = Scoring.repo(stars: hit.stars, delta: delta, createdAt: hit.createdAt, now: now)
            let item = FeedItem(
                id: "repo:\(key)",
                kind: .repo,
                title: hit.fullName.split(separator: "/").last.map(String.init) ?? hit.fullName,
                subtitle: String(hit.fullName.split(separator: "/").first ?? ""),
                summary: hit.description,
                url: hit.url,
                imageURL: hit.imageURL,
                avatarURL: hit.avatarURL,
                stars: hit.stars,
                language: hit.language,
                starsDelta: delta,
                createdAt: hit.createdAt,
                foundAt: now,
                score: score,
                lane: hit.lane,
                visitedAt: existingItem?.visitedAt
            )
            if byID[item.id] == nil { added += 1 }
            byID[item.id] = item
        }

        for hit in releases {
            let key = "release:\(hit.repo.lowercased())@\(hit.title)"
            if byID[key] != nil { continue }
            let item = FeedItem(
                id: key,
                kind: .release,
                title: hit.title,
                subtitle: hit.repo,
                summary: String(hit.notes.prefix(220)),
                url: hit.url,
                imageURL: URL(string: "https://opengraph.githubassets.com/1/\(hit.repo)"),
                avatarURL: nil,
                stars: nil,
                language: nil,
                starsDelta: nil,
                createdAt: hit.publishedAt,
                foundAt: now,
                score: 26 + Scoring.ageBonus(hit.publishedAt, now: now),
                lane: "关注项目"
            )
            byID[key] = item
            added += 1
        }

        for hit in stories {
            let key = "story:\(hit.url.absoluteString)"
            if byID[key] != nil { continue }
            let item = FeedItem(
                id: key,
                kind: .story,
                title: hit.title,
                subtitle: hit.domain,
                summary: "",
                url: hit.url,
                imageURL: nil,
                avatarURL: nil,
                stars: hit.points,
                language: nil,
                starsDelta: nil,
                createdAt: hit.publishedAt,
                foundAt: now,
                score: 12 + min(20, Double(hit.points) / 25) + Scoring.ageBonus(hit.publishedAt, now: now),
                lane: "讨论"
            )
            byID[key] = item
            added += 1
        }

        // 第一次拉会一口气几百条，那不是 feed 是仓库列表。一天最多进 60 条，按分数挑。
        let existingIDs = Set(existing.map { $0.id })
        let fresh = byID.values.filter { $0.foundAt == now && !existingIDs.contains($0.id) }
        if fresh.count > 60 {
            let keep = Set(fresh.sorted { $0.score > $1.score }.prefix(60).map { $0.id })
            for item in fresh where !keep.contains(item.id) {
                byID.removeValue(forKey: item.id)
            }
        }

        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86_400)
        var items = byID.values
            .filter { $0.foundAt >= cutoff && !$0.muted }
            .sorted { $0.foundAt > $1.foundAt }

        // 同一天里按分数排，跨天按发现时间分节。
        items.sort { lhs, rhs in
            if Calendar.current.isDate(lhs.foundAt, inSameDayAs: rhs.foundAt) {
                return lhs.score > rhs.score
            }
            return lhs.foundAt > rhs.foundAt
        }
        if items.count > 400 {
            items = Array(items.prefix(400))
        }
        return (items, index, added)
    }
}

extension Merge {
    static func isList(_ fullName: String, description: String) -> Bool {
        let name = fullName.lowercased()
        if name.contains("awesome-") || name.hasSuffix("/awesome") { return true }
        let text = description.lowercased()
        return text.hasPrefix("a curated list") || text.hasPrefix("curated list of")
            || text.contains("awesome list")
    }
}

enum Scoring {
    /// 越新越加分，14 天内线性，之后归零。
    static func ageBonus(_ date: Date, now: Date) -> Double {
        let days = now.timeIntervalSince(date) / 86_400
        return max(0, 14 - days)
    }

    static func repo(stars: Int, delta: Int?, createdAt: Date, now: Date) -> Double {
        var score = 6 * log10(1 + Double(stars))
        if let delta, delta > 0 {
            score += 9 * log10(1 + Double(delta))
        }
        let days = now.timeIntervalSince(createdAt) / 86_400
        score += max(0, 30 - days) * 1.1
        return score
    }
}

extension JSONEncoder {
    static var openFeed: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

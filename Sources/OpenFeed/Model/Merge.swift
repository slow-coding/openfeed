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
    /// 只留今天和昨天：他自己说的，只看当天，最多回退一天。
    static let keepDays = 2
    /// 你的六条线。不在这里面的都是探索项。
    static let coreLanes: Set<String> = [
        "上下文记忆", "记忆图谱", "Agent", "编程智能体", "生成式界面", "动效视觉", "关注项目", "讨论"
    ]

    static func run(repos: [RepoHit], releases: [ReleaseHit], stories: [StoryHit],
                    existing: [FeedItem], seen: SeenIndex, prefs: Preferences,
                    order: [String: [String]], now: Date)
        -> (items: [FeedItem], seen: SeenIndex, added: Int, order: [String: [String]]) {
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

        var freshIDs: [String] = []

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
                if hit.velocity {
                    index.repos[key] = SeenRepo(stars: hit.stars, firstSeen: now, lastSeen: now)
                    continue
                }
            } else if let existingItem {
                // 见过的项目不再进今天的流，只有这几天又涨了不少才重新冒上来。
                let days = now.timeIntervalSince(existingItem.foundAt) / 86_400
                if !(climbed && days >= 3) { continue }
            } else {
                // 上一轮被上限挤掉的：只有涨星才给它第二次机会。
                if !climbed { continue }
            }

            index.repos[key] = SeenRepo(
                stars: hit.stars,
                firstSeen: previous?.firstSeen ?? now,
                lastSeen: now
            )

            let exploration = !coreLanes.contains(hit.lane)
            var item = FeedItem(
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
                lane: hit.lane,
                visitedAt: existingItem?.visitedAt,
                isExploration: exploration
            )
            let scored = ValueModel.score(item, prefs: prefs, now: now)
            item.value = scored.value
            item.reasons = scored.reasons
            if byID[item.id] == nil { added += 1; freshIDs.append(item.id) }
            byID[item.id] = item
        }

        for hit in releases {
            let key = "release:\(hit.repo.lowercased())@\(hit.title)"
            if byID[key] != nil { continue }
            var item = FeedItem(
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
                lane: "关注项目"
            )
            let scored = ValueModel.score(item, prefs: prefs, now: now)
            item.value = scored.value
            item.reasons = scored.reasons
            byID[key] = item
            added += 1
            freshIDs.append(item.id)
        }

        for hit in stories {
            let key = "story:\(hit.url.absoluteString)"
            if byID[key] != nil { continue }
            var item = FeedItem(
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
                lane: "讨论"
            )
            let scored = ValueModel.score(item, prefs: prefs, now: now)
            item.value = scored.value
            item.reasons = scored.reasons
            byID[key] = item
            added += 1
            freshIDs.append(item.id)
        }

        // 一天最多进 60 条，按价值挑；被挤掉的照样在 seen 里，只是今天不上版面。
        let existingIDs = Set(existing.map { $0.id })
        let fresh = byID.values.filter { $0.foundAt == now && !existingIDs.contains($0.id) }
        if fresh.count > 60 {
            let keep = Set(fresh.sorted { $0.value > $1.value }.prefix(60).map { $0.id })
            for item in fresh where !keep.contains(item.id) {
                byID.removeValue(forKey: item.id)
            }
        }

        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86_400)
        var items = byID.values.filter { $0.foundAt >= cutoff }

        // 一天最多留 60 条：一天里手动点多几次，不能越堆越多。
        let todayKeyForCap = ImageStore.dayKey(now)
        let todayItems = items.filter { ImageStore.dayKey($0.foundAt) == todayKeyForCap }
        if todayItems.count > 60 {
            let keep = Set(todayItems.sorted { lhs, rhs in
                if (lhs.visitedAt != nil) != (rhs.visitedAt != nil) { return lhs.visitedAt != nil }
                return lhs.value > rhs.value
            }.prefix(60).map { $0.id })
            for item in todayItems where !keep.contains(item.id) {
                byID.removeValue(forKey: item.id)
            }
            items = items.filter { keep.contains($0.id) || ImageStore.dayKey($0.foundAt) != todayKeyForCap }
        }

        // 偏好会变：每次拉取都按当前权重重算一遍价值，排序才是「动态」的。
        for index in items.indices {
            let scored = ValueModel.score(items[index], prefs: prefs, now: now)
            items[index].value = scored.value
            items[index].reasons = scored.reasons
            if items[index].coreLine == nil {
                items[index].coreLine = CoreValue.cached(items[index].id)
            }
        }

        // 偏好变了，没手动排过的那部分要跟着重排。
        items.sort { lhs, rhs in
            if Calendar.current.isDate(lhs.foundAt, inSameDayAs: rhs.foundAt) {
                return lhs.value > rhs.value
            }
            return lhs.foundAt > rhs.foundAt
        }
        if items.count > 400 { items = Array(items.prefix(400)) }

        // 今天新进来的顶在最上面，剩下的保持你拖过的顺序。
        let todayKey = ImageStore.dayKey(now)
        let keptToday = (order[todayKey] ?? []).filter { id in items.contains { $0.id == id } }
        let newToday = items
            .filter { ImageStore.dayKey($0.foundAt) == todayKey && !keptToday.contains($0.id) }
            .sorted { $0.value > $1.value }
            .map { $0.id }
        var nextOrder = order
        nextOrder[todayKey] = newToday + keptToday
        // 过期的日子不再占地方
        for key in nextOrder.keys where key < ImageStore.dayKey(cutoff) {
            nextOrder.removeValue(forKey: key)
        }

        return (items, index, added, nextOrder)
    }

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
}

extension JSONEncoder {
    static var openFeed: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

import Foundation
import Combine

@MainActor
final class FeedStore: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running(String)
        case failed(String)

        var isRunning: Bool { if case .running = self { return true }; return false }
    }

    @Published private(set) var snapshot: FeedSnapshot
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var prefs: Preferences
    @Published private(set) var lastAdded: Int = 0
    /// 指针停在哪一条上（预览窗靠它决定显示什么）
    @Published var hoveredID: String?

    private(set) var config: FeedConfig

    private var seen: SeenIndex
    private var retryAfter: Date?

    init() {
        Paths.ensure()
        config = FeedConfig.load()
        snapshot = Self.loadSnapshot()
        seen = SeenIndex.load()
        prefs = Preferences.load()
    }

    // MARK: - 读

    var items: [FeedItem] { snapshot.items }

    func item(_ id: String) -> FeedItem? { snapshot.items.first { $0.id == id } }

    var hoveredItem: FeedItem? { hoveredID.flatMap(item) }

    func unread(todayOnly: Bool = true) -> Int {
        snapshot.items.filter { item in
            guard item.visitedAt == nil else { return false }
            return todayOnly ? item.isNewToday : true
        }.count
    }

    /// 按「发现的那一天」分节；同一天里按你拖过的顺序，没拖过的按价值排。
    func sections() -> [(day: Date, items: [FeedItem])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [FeedItem]] = [:]
        for item in snapshot.items {
            let day = calendar.startOfDay(for: item.foundAt)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(item)
        }
        return order.map { day in
            let bucket = buckets[day] ?? []
            let stored = snapshot.order[ImageStore.dayKey(day)] ?? []
            guard !stored.isEmpty else {
                return (day, bucket.sorted { $0.value > $1.value })
            }
            let rank = Dictionary(uniqueKeysWithValues: stored.enumerated().map { ($1, $0) })
            let sorted = bucket.sorted { lhs, rhs in
                let left = rank[lhs.id] ?? Int.max
                let right = rank[rhs.id] ?? Int.max
                if left == right { return lhs.value > rhs.value }
                return left < right
            }
            return (day, sorted)
        }
    }

    var cacheText: String { ImageStore.shared.totalText }

    // MARK: - 写

    func setHour(_ hour: Int) {
        config.hour = hour
        config.save()
    }

    func setHover(_ item: FeedItem?) {
        let next = item?.id
        if hoveredID != next { hoveredID = next }
    }

    func markVisited(_ item: FeedItem) {
        guard let index = snapshot.items.firstIndex(where: { $0.id == item.id }) else { return }
        if snapshot.items[index].visitedAt == nil {
            snapshot.items[index].visitedAt = Date()
            prefs.noteClick(item)
            prefs.save()
            save()
        }
    }

    func markAllVisited() {
        let now = Date()
        for index in snapshot.items.indices where snapshot.items[index].visitedAt == nil {
            snapshot.items[index].visitedAt = now
        }
        save()
    }

    func mute(_ item: FeedItem) {
        if item.isRepo {
            let key = item.subtitle.lowercased() + "/" + item.title.lowercased()
            if !seen.muted.contains(key) { seen.muted.append(key) }
            seen.save()
        }
        snapshot.items.removeAll { $0.id == item.id }
        save()
    }

    /// 拖一次：重排这一天，并把「谁该在谁上面」喂给偏好。
    func move(_ id: String, before targetID: String, day: Date) {
        guard id != targetID else { return }
        let key = ImageStore.dayKey(day)
        let current = sections().first { Calendar.current.isDate($0.day, inSameDayAs: day) }?.items ?? []
        var ids = current.map { $0.id }
        guard let from = ids.firstIndex(of: id), let targetIndex = ids.firstIndex(of: targetID) else { return }

        var to = targetIndex
        if from < to { to -= 1 }
        guard from != to else { return }

        let passed = from < targetIndex
            ? Array(ids[(from + 1)...targetIndex])
            : Array(ids[targetIndex..<from])
        ids.remove(at: from)
        ids.insert(id, at: to)
        snapshot.order[key] = ids

        if let moved = item(id) {
            for otherID in passed.prefix(3) {
                guard let other = item(otherID) else { continue }
                if from > targetIndex {
                    prefs.learn(winner: moved, loser: other)
                } else {
                    prefs.learn(winner: other, loser: moved)
                }
            }
            prefs.save()
            rescore()
        }
        save()
    }

    /// 偏好变了就当场重算价值：拖完立刻能看到「价值」跟着动，这才叫在学我。
    func rescore() {
        let now = Date()
        for index in snapshot.items.indices {
            let scored = ValueModel.score(snapshot.items[index], prefs: prefs, now: now)
            snapshot.items[index].value = scored.value
            snapshot.items[index].reasons = scored.reasons
        }
    }

    func resetPreferences() {
        prefs = Preferences()
        prefs.save()
        snapshot.order = [:]
        save()
    }

    @discardableResult
    func clearCache() -> Int {
        let count = ImageStore.shared.clear()
        snapshot.lastCacheSweep = Date()
        snapshot.lastCacheSweepCount = count
        save()
        return count
    }

    // MARK: - 拉取

    /// - Parameter manual: 手点的。手点的不管今天是第几次都跑；自动的看时间窗。
    func refresh(manual: Bool) async {
        guard !phase.isRunning else { return }
        if !manual, let retryAfter, Date() < retryAfter { return }

        let fetcher = Fetcher()
        let now = Date()
        let authorized = fetcher.authorized
        let queries = config.queries.filter { authorized || !$0.needsAuth }
        let total = queries.count

        phase = .running("搜索 0/\(total)")

        async let releaseHits = loadReleases(fetcher: fetcher, since: now.addingTimeInterval(-14 * 86_400))
        async let storyHits = loadStories(fetcher: fetcher, since: now.addingTimeInterval(-14 * 86_400))

        var repos: [RepoHit] = []
        var report: [String] = []
        var failures = 0
        var done = 0
        var rateLimited = false

        // 三条一并发：一条 0.8 秒，串着跑就是十几秒的转圈。
        for chunk in queries.chunked(3) {
            if rateLimited { break }
            let results = await withTaskGroup(of: (QueryConfig, Result<[RepoHit], Error>).self) { group in
                for query in chunk {
                    group.addTask {
                        do { return (query, .success(try await fetcher.search(query, now: now))) }
                        catch { return (query, .failure(error)) }
                    }
                }
                var collected: [(QueryConfig, Result<[RepoHit], Error>)] = []
                for await result in group { collected.append(result) }
                return collected
            }
            for (query, result) in results {
                done += 1
                phase = .running("搜索 \(done)/\(total) · \(query.lane)")
                switch result {
                case .success(let hits):
                    repos.append(contentsOf: hits)
                    report.append("\(query.lane) \(hits.count)")
                case .failure(let error):
                    failures += 1
                    report.append("\(query.lane) ✗ \(error.localizedDescription)")
                    if let fetchError = error as? FetchError, fetchError.isRateLimit {
                        rateLimited = true
                        if case .rateLimited(_, let reset) = fetchError {
                            retryAfter = reset ?? Date().addingTimeInterval(60)
                        }
                    }
                }
            }
        }

        phase = .running("版本与讨论")
        let releases = await releaseHits
        let stories = await storyHits
        report.append("版本 \(releases.count) 条 / 讨论 \(stories.count) 条")
        if !authorized { report.append("未授权：只跑 \(total) 条查询，额度 10 次/分") }

        prefs.decay()
        prefs.save()

        let merged = Merge.run(repos: repos, releases: releases, stories: stories,
                               existing: snapshot.items, seen: seen, prefs: prefs,
                               order: snapshot.order, now: now)
        seen = merged.seen
        seen.save()
        lastAdded = merged.added

        // 撞额度算「没拉全」：这一批先用着，但不算今天已完成，额度回来后会再补一次。
        let succeeded = !rateLimited && failures <= max(1, queries.count / 4)
        snapshot = FeedSnapshot(
            generatedAt: now,
            items: merged.items,
            lastSuccessAt: succeeded ? now : snapshot.lastSuccessAt,
            report: report,
            order: merged.order,
            lastCacheSweep: snapshot.lastCacheSweep,
            lastCacheSweepCount: snapshot.lastCacheSweepCount
        )

        if succeeded {
            Task.detached(priority: .utility) { [items = merged.items] in
                await KeyImage.prewarm(items: items, limit: 12)
            }
            // 只留今天和昨天的图，更老的在盘上不该继续占地方。
            let keep: Set<String> = [
                ImageStore.dayKey(now),
                ImageStore.dayKey(now.addingTimeInterval(-86_400))
            ]
            let removed = ImageStore.shared.prune(keeping: keep)
            snapshot.lastCacheSweep = Date()
            snapshot.lastCacheSweepCount = removed
            phase = .idle
            retryAfter = nil
        } else {
            phase = .failed(rateLimited ? "搜索额度用完了，过一会再试"
                                        : "搜索全挂了：\(report.first ?? "")")
            if !rateLimited { retryAfter = Date().addingTimeInterval(15 * 60) }
        }
        save()
    }

    private func loadReleases(fetcher: Fetcher, since: Date) async -> [ReleaseHit] {
        var all: [ReleaseHit] = []
        await withTaskGroup(of: [ReleaseHit].self) { group in
            var queue = config.releases.makeIterator()
            var running = 0
            while running < 6, let repo = queue.next() {
                group.addTask { await fetcher.releases(for: repo, since: since) }
                running += 1
            }
            while let done = await group.next() {
                all.append(contentsOf: done)
                if let repo = queue.next() {
                    group.addTask { await fetcher.releases(for: repo, since: since) }
                }
            }
        }
        return all.sorted { $0.publishedAt > $1.publishedAt }
    }

    private func loadStories(fetcher: Fetcher, since: Date) async -> [StoryHit] {
        var all: [StoryHit] = []
        await withTaskGroup(of: [StoryHit].self) { group in
            for query in config.stories {
                group.addTask { await fetcher.stories(query: query, since: since) }
            }
            for await hits in group {
                all.append(contentsOf: hits)
            }
        }
        return all
    }

    // MARK: - 盘

    private static func loadSnapshot() -> FeedSnapshot {
        guard let data = try? Data(contentsOf: Paths.feed),
              let snapshot = try? JSONDecoder.openFeed.decode(FeedSnapshot.self, from: data)
        else {
            return FeedSnapshot(generatedAt: .distantPast, items: [], lastSuccessAt: nil)
        }
        return snapshot
    }

    private func save() {
        guard let data = try? JSONEncoder.openFeed.encode(snapshot) else { return }
        try? data.write(to: Paths.feed, options: .atomic)
    }
}

/// 每天的那个点 + 睡醒补跑。规则只有一条：过了点、今天还没成功拉过，就拉。
enum Scheduler {
    static func isDue(lastSuccess: Date?, now: Date = Date(), hour: Int) -> Bool {
        let calendar = Calendar.current
        guard let today = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) else { return false }
        guard now >= today else { return false }
        guard let lastSuccess else { return true }
        return lastSuccess < today
    }

    static func nextRun(hour: Int, now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let today = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
        if now < today { return today }
        return calendar.date(byAdding: .day, value: 1, to: today) ?? today
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

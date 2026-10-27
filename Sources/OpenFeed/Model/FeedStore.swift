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
    @Published private(set) var lastAttempt: Date?
    /// 拉完一批之后涨了没有，给状态栏做一次短暂的强调用
    @Published private(set) var lastAdded: Int = 0

    @Published private(set) var config: FeedConfig

    private var seen: SeenIndex
    private var retryAfter: Date?

    init() {
        Paths.ensure()
        config = FeedConfig.load()
        snapshot = Self.loadSnapshot()
        seen = SeenIndex.load()
    }

    // MARK: - 读

    var items: [FeedItem] { snapshot.items }

    var newCount: Int {
        snapshot.items.filter { $0.foundAt > (snapshot.lastSuccessAt ?? .distantPast) && $0.visitedAt == nil }.count
    }

    func unread(todayOnly: Bool = true) -> Int {
        snapshot.items.filter { item in
            guard item.visitedAt == nil else { return false }
            return todayOnly ? item.isNewToday : true
        }.count
    }

    /// 按「发现的那一天」分节，新的在上。
    func sections() -> [(day: Date, items: [FeedItem])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [FeedItem]] = [:]
        for item in snapshot.items {
            let day = calendar.startOfDay(for: item.foundAt)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(item)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    // MARK: - 写

    func setHour(_ hour: Int) {
        config.hour = hour
        config.save()
    }

    func markVisited(_ item: FeedItem) {
        guard let index = snapshot.items.firstIndex(where: { $0.id == item.id }) else { return }
        if snapshot.items[index].visitedAt != nil { return }
        snapshot.items[index].visitedAt = Date()
        save()
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

    // MARK: - 拉取

    /// - Parameter manual: 手点的。手点的不管今天是第几次都跑；自动的看时间窗。
    func refresh(manual: Bool) async {
        guard !phase.isRunning else { return }
        if !manual, let retryAfter, Date() < retryAfter { return }

        lastAttempt = Date()
        let fetcher = Fetcher()
        let now = Date()
        let authorized = fetcher.authorized
        let queries = config.queries.filter { authorized || !$0.needsAuth }
        let total = queries.count

        phase = .running("搜索 0/\(total)")
        defer { save() }

        async let releaseHits = loadReleases(fetcher: fetcher, since: now.addingTimeInterval(-14 * 86_400))
        async let storyHits = loadStories(fetcher: fetcher, since: now.addingTimeInterval(-14 * 86_400))

        var repos: [RepoHit] = []
        var report: [String] = []
        var failures = 0
        var done = 0
        var rateLimited = false

        // 三条一并发：一条 0.8 秒，十四条串着跑就是十几秒的转圈。
        rateLimited = false
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

        let merged = Merge.run(repos: repos, releases: releases, stories: stories,
                               existing: snapshot.items, seen: seen, now: now)
        seen = merged.seen
        seen.save()
        lastAdded = merged.added
        snapshot = FeedSnapshot(
            generatedAt: now,
            items: merged.items,
            lastSuccessAt: failures == queries.count ? snapshot.lastSuccessAt : now,
            report: report
        )

        if !rateLimited { retryAfter = nil }
        if failures == queries.count, !queries.isEmpty {
            phase = .failed(rateLimited ? "搜索额度用完了，过一会再试" : "搜索全挂了：\(report.first ?? "")")
            if !rateLimited { retryAfter = Date().addingTimeInterval(15 * 60) }
        } else {
            phase = .idle
        }
        save()
    }

    private func loadReleases(fetcher: Fetcher, since: Date) async -> [ReleaseHit] {
        var all: [ReleaseHit] = []
        await withTaskGroup(of: [ReleaseHit].self) { group in
            var queue = config.releases.makeIterator()
            var running = 0
            // 同时最多 6 条 atom 请求，别把网络堆满
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

import Foundation

/// 你给条目打的分，1~5 星，0 = 没打。按条目 id 存，永久留着：
/// 同一个项目以后又冒出来时，分还在。
enum Ratings {
    private static var cache: [String: Int]?
    private static let lock = NSLock()

    static func value(_ id: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if cache == nil { cache = load() }
        return cache?[id] ?? 0
    }

    static func set(_ id: String, stars: Int) {
        lock.lock()
        if cache == nil { cache = load() }
        if stars <= 0 {
            cache?[id] = nil
        } else {
            cache?[id] = min(5, max(1, stars))
        }
        let snapshot = cache ?? [:]
        lock.unlock()
        guard let data = try? JSONEncoder.openFeed.encode(snapshot) else { return }
        try? data.write(to: Paths.ratings, options: .atomic)
    }

    private static func load() -> [String: Int] {
        guard let data = try? Data(contentsOf: Paths.ratings),
              let decoded = try? JSONDecoder.openFeed.decode([String: Int].self, from: data)
        else { return [:] }
        return decoded
    }
}

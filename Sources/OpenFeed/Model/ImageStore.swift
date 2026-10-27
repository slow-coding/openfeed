import Foundation
import AppKit

/// 图都落在这里（Caches），带一份清单，能算出多大、能按天清掉。
/// 保留口径跟着 feed 走：今天 + 昨天，再老的在每次拉取后扫掉。
final class ImageStore {
    static let shared = ImageStore()

    struct Entry: Codable {
        var file: String
        var bytes: Int
        var storedAt: Date
        var day: String
    }

    private var manifest: [String: Entry] = [:]
    private let lock = NSLock()

    private var directory: URL { Paths.images }
    private var manifestURL: URL { Paths.imageManifest }

    init() { load() }

    private func load() {
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder.openFeed.decode([String: Entry].self, from: data)
        else { return }
        manifest = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder.openFeed.encode(manifest) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    /// key 是「仓库 + 源图地址」的指纹，同一个仓库换了图也能区分开。
    func cached(_ key: String) -> Data? {
        lock.lock()
        let entry = manifest[key]
        lock.unlock()
        guard let entry else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(entry.file))
    }

    func store(_ data: Data, key: String, itemID: String?, day dayOverride: String? = nil) -> Bool {
        let day = dayOverride ?? Self.dayKey(Date())
        let name = Self.hash(key) + ".png"
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard (try? data.write(to: directory.appendingPathComponent(name), options: .atomic)) != nil else {
            return false
        }
        lock.lock()
        manifest[key] = Entry(file: name, bytes: data.count, storedAt: Date(), day: day)
        lock.unlock()
        save()
        return true
    }

    /// 清掉不属于这些日子的图。days 传进来的是「还留着的日子」，格式 yyyy-MM-dd。
    @discardableResult
    func prune(keeping days: Set<String>) -> Int {
        lock.lock()
        let doomed = manifest.filter { !days.contains($0.value.day) }
        for (key, entry) in doomed {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.file))
            manifest.removeValue(forKey: key)
        }
        lock.unlock()
        save()

        // 头像不走清单，按文件时间扫
        let cutoff = Date().addingTimeInterval(-2 * 86_400)
        if let files = try? FileManager.default.contentsOfDirectory(at: Paths.avatars,
                                                                    includingPropertiesForKeys: [.contentModificationDateKey]) {
            for file in files {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if modified < cutoff { try? FileManager.default.removeItem(at: file) }
            }
        }
        return doomed.count
    }

    @discardableResult
    func clear() -> Int {
        lock.lock()
        let count = manifest.count
        manifest.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: Paths.avatars)
        try? FileManager.default.removeItem(at: manifestURL)
        ThumbCache.shared.forget()
        return count
    }

    var totalBytes: Int {
        var total = 0
        for dir in [directory, Paths.avatars] {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey]
            ) else { continue }
            for file in files {
                total += (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            }
        }
        return total
    }

    var totalText: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
    }

    static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func hash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}

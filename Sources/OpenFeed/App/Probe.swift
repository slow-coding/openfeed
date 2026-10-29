import AppKit
import SwiftUI

/// 自检口子：不点鼠标也能验这一轮的东西。
///   OpenFeed --probe --fetch                 拉一次，打印统计
///   OpenFeed --probe --snapshot <目录>        把面板按深 / 浅两档离屏渲染成 PNG
///   OpenFeed --probe --dump                  只打印盘上那份数据的统计
final class BackdropView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
}

enum Probe {
    static var isRequested: Bool { CommandLine.arguments.contains("--probe") }

    @MainActor
    static func run(store: FeedStore) async {
        let arguments = CommandLine.arguments
        var report: [String: Any] = [:]
        report["authorized"] = Auth.source

        // 菜单里那条「语言」走的同一个入口，自检时不必去点菜单。
        if let index = arguments.firstIndex(of: "--set-lang"), index + 1 < arguments.count {
            let code = arguments[index + 1]
            store.setLanguage(code)
            report["uiLang"] = FeedConfig.load().uiLang
            report["uiSample"] = [
                "header": L.t("今天", "Today"),
                "chip": L.t("仓库", "Repos"),
                "value": L.t("价值 18", "value 18")
            ]
        }

        if arguments.contains("--fetch") {
            let started = Date()
            await store.refresh(manual: true)
            report["fetchSeconds"] = Int(Date().timeIntervalSince(started).rounded())
            report["phase"] = describe(store.phase)
            report["report"] = store.snapshot.report
        }

        let today = store.items.filter { $0.isNewToday }
        var byKind: [String: Int] = [:]
        for item in store.items { byKind[item.kind.rawValue, default: 0] += 1 }
        var byLane: [String: Int] = [:]
        for item in today { byLane[item.lane, default: 0] += 1 }

        report["seenRepos"] = SeenIndex.load().repos.count
        report["cache"] = ImageStore.shared.totalText
        report["prefsPairs"] = store.prefs.pairs
        report["docBoosts"] = PreferencesDoc.boosts().sorted { $0.value > $1.value }
            .map { "\($0.key)=\(String(format: "%.2f", $0.value))" }
        report["prefsWeights"] = store.prefs.weights.sorted { $0.value > $1.value }.prefix(8)
            .map { "\($0.key)=\(String(format: "%.2f", $0.value))" }
        report["items"] = store.items.count
        report["today"] = today.count
        report["byKind"] = byKind
        report["todayByLane"] = byLane
        report["lastSuccess"] = store.snapshot.lastSuccessAt.map(ISO8601DateFormatter().string) ?? "never"
        report["withImage"] = store.items.filter { $0.imageURL != nil }.count
        report["copySample"] = today.prefix(2).map { $0.copyText }
        report["top"] = today.prefix(8).map { item -> [String: Any] in
            [
                "kind": item.kind.rawValue,
                "lane": item.lane,
                "title": item.title,
                "subtitle": item.subtitle,
                "stars": item.stars ?? -1,
                "delta": item.starsDelta ?? -1,
                "age": item.createdAt.agoText,
                "value": Int(item.value.rounded()),
                "reasons": item.reasons,
                "explore": item.isExploration,
                "core": item.coreLine ?? "",
                "summary": String(item.summary.prefix(90))
            ]
        }

        if arguments.contains("--headline-check") {
            // release 标题的规则：版本号开头要剥掉，剥完没内容就不该出现，标题不能吊在虚词上。
            let cases: [(String, String?)] = [
                ("v2.2.0 Security: Node.js runtime and CA certificate updates (October 2026) On October 20", "Security: Node.js runtime and CA certificate"),
                ("Release 0.166.0-alpha.5.1", nil),
                ("2.13.0", nil),
                ("ai@7.0.156 Patch Changes - Updated dependencies [9f19c79]", nil),
                ("Patch Changes - Updated dependencies", nil),
                ("Changes since 1.2.17 release(checkpoint): 4.3.1 (9447) release(langgraph): 1.2.18", nil),
                ("New Features - Added a built-in Vertex AI provider, configured with GOOGLE_CLOUD_PROJECT", "Added a built-in Vertex AI provider, configured"),
                ("\n- Harness Agents in Teams and Workflows: ClaudeAgent and CodexAgent can now be members", "Harness Agents in Teams and Workflows:"),
                ("f59b4 Thanks @mattzcarey! - Upgrade the MCP server to MCP TypeScript SDK v2", "Thanks @mattzcarey! - Upgrade the MCP server"),
                ("added the missing retry so a dropped socket no longer wedges the worker", "added the missing retry so a dropped socket"),
                ("feat(verify): stand in for DigitalOcean so Managed Agents can be verified by @enyst", "feat(verify): stand in for DigitalOcean"),
                ("fix(core): allow trusted system paths on Android (Termux) for ripgrep resolution", "fix(core): allow trusted system paths")
            ]
            report["headlineCheck"] = cases.map { input, expected in
                let got = Fetcher.headline(input)?.title
                return [
                    "in": String(input.prefix(46)),
                    "want": expected ?? "(丢掉)",
                    "got": got ?? "(丢掉)",
                    "ok": got == expected
                ]
            }
        }

        if arguments.contains("--cache-check") {
            let store = ImageStore.shared
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            let today = fmt.string(from: Date())
            let yesterday = fmt.string(from: Date().addingTimeInterval(-86_400))
            let old = fmt.string(from: Date().addingTimeInterval(-3 * 86_400))
            _ = store.store(Data(repeating: 1, count: 2048), key: "test|today", itemID: nil, day: today)
            _ = store.store(Data(repeating: 1, count: 2048), key: "test|yesterday", itemID: nil, day: yesterday)
            _ = store.store(Data(repeating: 1, count: 2048), key: "test|old", itemID: nil, day: old)
            let removed = store.prune(keeping: [today, yesterday])
            report["cacheCheck"] = [
                "removed": removed,
                "todayStillCached": store.cached("test|today") != nil,
                "yesterdayStillCached": store.cached("test|yesterday") != nil,
                "oldStillCached": store.cached("test|old") != nil
            ]
        }

        if arguments.contains("--learn-check") {
            let todayItems = store.sections().first?.items ?? []
            if todayItems.count > 5 {
                let moved = todayItems[4]
                let target = todayItems[0]
                let before = moved.value
                store.move(moved.id, before: target.id, day: store.sections()[0].day)
                let after = store.item(moved.id)?.value ?? -1
                report["moveCheck"] = [
                    "moved": moved.title,
                    "above": target.title,
                    "valueBefore": Int(before.rounded()),
                    "valueAfter": Int(after.rounded()),
                    "newOrder": Array(store.sections()[0].items.prefix(3).map { $0.title }),
                    "pairs": store.prefs.pairs,
                    "weights": store.prefs.weights.sorted { abs($0.value) > abs($1.value) }.prefix(6)
                        .map { "\($0.key)=\(String(format: "%.2f", $0.value))" }
                ]
            }
        }

        if arguments.contains("--summaries") {
            await CoreValue.prewarm(items: today, limit: 60)
            var results: [[String: Any]] = []
            for item in today.prefix(6) {
                let started = Date()
                let line = await CoreValue.line(for: item)
                results.append([
                    "title": item.title,
                    "kind": item.kind.rawValue,
                    "line": line ?? "(nil)",
                    "ms": Int(Date().timeIntervalSince(started) * 1000)
                ])
            }
            store.fillCoreLines()
            report["summaries"] = results
            report["keySource"] = CoreValue.keySource
        }

        if let index = arguments.firstIndex(of: "--prefs-shot"), index + 1 < arguments.count {
            let directory = URL(fileURLWithPath: arguments[index + 1])
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let size = NSSize(width: 600, height: 560)
            let root = BackdropView(frame: NSRect(origin: .zero, size: size))
            let host = NSHostingView(rootView: PreferencesView(text: PreferencesDoc.load(), onSave: { _ in }))
            host.frame = root.bounds
            host.autoresizingMask = [.width, .height]
            root.addSubview(host)
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = root
            window.orderFrontRegardless()
            try? await Task.sleep(nanoseconds: 600_000_000)
            if let png = capture(root) {
                try? png.write(to: directory.appendingPathComponent("prefs.png"))
                report["prefsShot"] = directory.appendingPathComponent("prefs.png").path
            }
            window.orderOut(nil)
        }

        if let index = arguments.firstIndex(of: "--swap-check"), index + 1 < arguments.count {
            let directory = URL(fileURLWithPath: arguments[index + 1])
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let repos = today.filter { $0.kind == .repo }
            if repos.count > 2 {
                let a = repos[0], b = repos[2]
                _ = await KeyImage.display(a)
                _ = await KeyImage.display(b)
                report["swapCheck"] = await swapRender(a: a, b: b, directory: directory)
            }
        }

        if arguments.contains("--rate-check") {
            if let first = store.sections().first?.items.first {
                let before = first.value
                store.setRating(4, for: first)
                let after = store.item(first.id)
                report["rateCheck"] = [
                    "title": first.title,
                    "valueBefore": Int(before.rounded()),
                    "valueAfter": Int((after?.value ?? -1).rounded()),
                    "rating": after?.rating ?? -1,
                    "persisted": Ratings.value(first.id),
                    "reasons": after?.reasons ?? [],
                    "orderFrozen": store.snapshot.order[ImageStore.dayKey(first.foundAt)]?.count ?? 0
                ]

            }
        }

        if arguments.contains("--images") {
            var results: [[String: Any]] = []
            for item in today.filter({ $0.kind == .repo }).prefix(5) {
                let started = Date()
                let data = await KeyImage.display(item)
                results.append([
                    "repo": item.repoSlug ?? item.title,
                    "bytes": data?.count ?? -1,
                    "ms": Int(Date().timeIntervalSince(started) * 1000),
                    "key": item.keyImagePath ?? ""
                ])
            }
            report["images"] = results
            report["cacheAfter"] = ImageStore.shared.totalText
        }

        if arguments.contains("--schedule") {
            let calendar = Calendar.current
            let today9 = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
            let cases: [(String, Date?, Date)] = [
                ("昨晚 22:00 拉过，现在 08:59", today9.addingTimeInterval(-11 * 3_600), today9.addingTimeInterval(-60)),
                ("昨晚 22:00 拉过，现在 09:01", today9.addingTimeInterval(-11 * 3_600), today9.addingTimeInterval(60)),
                ("今天 09:05 拉过，现在 09:30", today9.addingTimeInterval(5 * 60), today9.addingTimeInterval(30 * 60)),
                ("从没拉过，现在 08:00", nil, today9.addingTimeInterval(-3_600)),
                ("从没拉过，现在 23:00", nil, today9.addingTimeInterval(14 * 3_600))
            ]
            report["schedule"] = cases.map { name, last, now in
                ["case": name, "due": Scheduler.isDue(lastSuccess: last, now: now, hour: 9)]
            }
        }

        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            let directory = URL(fileURLWithPath: arguments[index + 1])
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, appearance) in [("panel-dark", NSAppearance(named: .darkAqua)),
                                       ("panel-light", NSAppearance(named: .aqua))] {
                if let data = await render(store: store, appearance: appearance) {
                    try? data.write(to: directory.appendingPathComponent("\(name).png"))
                }
            }
            report["snapshotDir"] = directory.path
        }

        if let index = arguments.firstIndex(of: "--preview"), index + 1 < arguments.count,
           let item = store.sections().first?.items.first {
            let directory = URL(fileURLWithPath: arguments[index + 1])
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = await KeyImage.display(item)
            for (name, appearance) in [("preview-dark", NSAppearance(named: .darkAqua)),
                                       ("preview-light", NSAppearance(named: .aqua))] {
                if let data = await renderPreview(item: item, appearance: appearance) {
                    try? data.write(to: directory.appendingPathComponent("\(name).png"))
                }
            }
        }

        if let data = try? JSONSerialization.data(withJSONObject: report,
                                                   options: [.prettyPrinted, .sortedKeys]) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write("\n".data(using: .utf8)!)
        }
        NSApp.terminate(nil)
        exit(0)
    }

    private static func describe(_ phase: FeedStore.Phase) -> String {
        switch phase {
        case .idle: return "idle"
        case .running(let text): return "running: \(text)"
        case .failed(let text): return "failed: \(text)"
        }
    }

    /// 同一块面板换一条内容：如果第二条还显示第一条的图，就是状态没重置。
    @MainActor
    private static func swapRender(a: FeedItem, b: FeedItem, directory: URL) async -> [String: Any] {
        let size = NSSize(width: PreviewCard.width, height: 470)
        let root = BackdropView(frame: NSRect(origin: .zero, size: size))
        let model = PreviewModel(item: a)
        let host = NSHostingView(rootView: PreviewCard(model: model, onOpen: {}))
        host.frame = root.bounds
        root.addSubview(host)

        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = root
        window.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        var shots: [[String: Any]] = []
        if let png = capture(root) {
            try? png.write(to: directory.appendingPathComponent("swap-a.png"))
            shots.append(["item": a.title, "bytes": png.count])
        }
        model.item = b
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if let png = capture(root) {
            try? png.write(to: directory.appendingPathComponent("swap-b.png"))
            shots.append(["item": b.title, "bytes": png.count])
        }
        window.orderOut(nil)
        return ["shots": shots,
                "sameBytes": (shots.count == 2) && (shots[0]["bytes"] as? Int) == (shots[1]["bytes"] as? Int)]
    }

    @MainActor
    private static func capture(_ view: NSView) -> Data? {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    @MainActor
    private static func renderPreview(item: FeedItem, appearance: NSAppearance?) async -> Data? {
        var size = PreviewController.size
        let root = BackdropView(frame: NSRect(origin: .zero, size: size))
        let card = PreviewCard(model: PreviewModel(item: item), onOpen: {})
        let host = NSHostingView(rootView: card)
        host.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        host.layoutSubtreeIfNeeded()
        let fit = host.fittingSize
        if fit.height > 200 {
            size = NSSize(width: max(size.width, fit.width), height: fit.height)
            root.frame = NSRect(origin: .zero, size: size)
            host.frame = root.bounds
        }
        host.autoresizingMask = [.width, .height]
        root.addSubview(host)

        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = root
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 1_800_000_000)
        // 图 / 一句话是异步来的，截之前按真实内容重新收一次高度
        host.layoutSubtreeIfNeeded()
        let fitted = host.fittingSize
        if fitted.height > 200, abs(fitted.height - size.height) > 2 {
            size = NSSize(width: size.width, height: fitted.height)
            root.frame = NSRect(origin: .zero, size: size)
            host.frame = root.bounds
            root.layoutSubtreeIfNeeded()
        }
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
            window.orderOut(nil)
            return nil
        }
        root.cacheDisplay(in: root.bounds, to: rep)
        window.orderOut(nil)
        return rep.representation(using: .png, properties: [:])
    }

    /// 把一个真的窗口摆到屏幕外再截图：这样 SwiftUI 的异步任务（缩略图）才会真的跑。
    @MainActor
    private static func render(store: FeedStore, appearance: NSAppearance?) async -> Data? {
        let size = NSSize(width: T.width, height: T.height)
        // 底色要现画，不能用 layer 的 cgColor：它是赋值那一刻的解析结果，切到浅色也不会变。
        let root = BackdropView(frame: NSRect(origin: .zero, size: size))

        let vibrancy = NSVisualEffectView(frame: root.bounds)
        vibrancy.material = .popover
        vibrancy.blendingMode = .withinWindow
        vibrancy.state = .active
        vibrancy.autoresizingMask = [.width, .height]
        root.addSubview(vibrancy)

        let panel = FeedPanel(
            store: store,
            onOpen: { _ in },
            onRefresh: {},
            onMenu: { _ in },
            forceHoverID: CommandLine.arguments.contains("--hover")
                ? store.sections().first?.items.first?.id : nil
        )
        let host = NSHostingView(rootView: panel)
        host.frame = root.bounds
        host.autoresizingMask = [.width, .height]
        vibrancy.addSubview(host)

        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isOpaque = false
        window.contentView = root
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()

        // 等缩略图下载 + 布局稳定。最多两秒，宁可少几张图也不卡在这里。
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        root.layoutSubtreeIfNeeded()

        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
            window.orderOut(nil)
            return nil
        }
        root.cacheDisplay(in: root.bounds, to: rep)
        window.orderOut(nil)
        return rep.representation(using: .png, properties: [:])
    }
}

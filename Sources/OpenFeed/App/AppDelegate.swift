import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = FeedStore()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var ticker: Timer?
    private var isRefreshing = false
    private var observers: [AnyCancellable] = []
    private let preview = PreviewController()
    private var hoverWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.render() }
            }
            .store(in: &observers)
        store.$hoveredID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.schedulePreview() }
            .store(in: &observers)
        setupStatusItem()
        setupPopover()
        observe()
        render()
        tick()

        // 第一次跑、盘上一份都没有：先拉一批，拉完自己弹一次面板，别让人对着一个空图标猜。
        if store.snapshot.items.isEmpty {
            Task {
                await refresh(manual: false)
                if !store.snapshot.items.isEmpty { togglePopover() }
            }
        }

        if UserDefaults.standard.object(forKey: "autoStart") == nil {
            if LoginItem.enable() { UserDefaults.standard.set(true, forKey: "autoStart") }
        } else if UserDefaults.standard.bool(forKey: "autoStart"), !LoginItem.isEnabled {
            LoginItem.enable()
        }

        if CommandLine.arguments.contains("--demo-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.togglePopover() }
        }

        // 自检：真开一次面板，报出它有没有弹出来、多大、状态栏那一格多宽。
        if CommandLine.arguments.contains("--self-check-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                self.togglePopover()
                var previewProbe = "hidden"
                if let first = self.store.sections().first?.items.first,
                   let window = self.popover.contentViewController?.view.window {
                    self.preview.show(item: first, beside: window) { _ in }
                    previewProbe = "\(self.preview.frameDescription) shown=\(self.preview.isShown)"
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    let button = self.statusItem.button
                    let report: [String: Any] = [
                        "popoverShown": self.popover.isShown,
                        "popoverSize": "\(self.popover.contentSize)",
                        "viewFrame": self.popover.contentViewController?.view.frame.debugDescription ?? "nil",
                        "statusWidth": button?.frame.width ?? -1,
                        "statusHeight": button?.frame.height ?? -1,
                        "title": button?.attributedTitle.string ?? "",
                        "imageSize": button?.image.map { "\($0.size)" } ?? "nil",
                        "items": self.store.items.count,
                        "unread": self.store.unread(todayOnly: true),
                        "previewAtShow": previewProbe,
                        "cache": self.store.cacheText,
                        "pairs": self.store.prefs.pairs
                    ]
                    if let data = try? JSONSerialization.data(withJSONObject: report,
                                                              options: [.prettyPrinted, .sortedKeys]) {
                        FileHandle.standardOutput.write(data)
                        FileHandle.standardOutput.write("\n".data(using: .utf8)!)
                    }
                    exit(0)
                }
            }
        }
    }

    // MARK: - 状态栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func render() {
        guard let button = statusItem.button else { return }
        button.image = StatusIcon.image()
        button.imagePosition = .imageLeading
        let unread = store.unread(todayOnly: true)
        if unread > 0 {
            let text = unread > 20 ? "20+" : "\(unread)"
            button.attributedTitle = NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
                    .foregroundColor: NSColor.labelColor,
                    .baselineOffset: 0.5
                ]
            )
        } else {
            button.attributedTitle = NSAttributedString(string: "")
        }
        button.toolTip = tooltip()
    }

    private func tooltip() -> String {
        if case .running(let text) = store.phase { return text }
        guard let last = store.snapshot.lastSuccessAt else { return "OpenFeed · 还没拉过" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return "OpenFeed · 上次 \(formatter.string(from: last)) · 每天 \(String(format: "%02d", store.config.hour)):00"
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu(anchor: nil)
        } else {
            togglePopover()
        }
    }

    // MARK: - 面板

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: T.width, height: T.height)
        let root = FeedPanel(
            store: store,
            onOpen: { [weak self] item in
                NSWorkspace.shared.open(item.url)
                self?.popover.performClose(nil)
            },
            onRefresh: { [weak self] in
                Task { await self?.refresh(manual: true) }
            },
            onMenu: { [weak self] anchor in
                self?.showMenu(anchor: anchor)
            }
        )
        popover.contentViewController = NSHostingController(rootView: root)
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            preview.hide()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// 悬停 180ms 才弹：划过一路不闪。
    private func schedulePreview() {
        hoverWork?.cancel()
        guard let item = store.hoveredItem, popover.isShown else {
            preview.hide()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let window = self.popover.contentViewController?.view.window else { return }
            self.preview.show(item: item, beside: window) { [weak self] item in
                guard let self else { return }
                self.store.markVisited(item)
                NSWorkspace.shared.open(item.url)
                self.popover.performClose(nil)
                self.preview.hide()
            }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    // MARK: - 菜单

    private func showMenu(anchor: NSView?) {
        let menu = NSMenu()

        let refreshItem = NSMenuItem(title: "现在拉取", action: #selector(menuRefresh), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.isEnabled = !store.phase.isRunning
        menu.addItem(refreshItem)

        let readItem = NSMenuItem(title: "全部标为已读", action: #selector(menuMarkRead), keyEquivalent: "")
        readItem.target = self
        menu.addItem(readItem)
        menu.addItem(.separator())

        let autoItem = NSMenuItem(title: "开机自启", action: #selector(menuToggleAutoStart), keyEquivalent: "")
        autoItem.target = self
        autoItem.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(autoItem)

        let hourMenu = NSMenu()
        for hour in 6...14 {
            let item = NSMenuItem(title: String(format: "%02d:00", hour), action: #selector(menuSetHour(_:)), keyEquivalent: "")
            item.target = self
            item.tag = hour
            item.state = hour == store.config.hour ? .on : .off
            hourMenu.addItem(item)
        }
        let hourItem = NSMenuItem(title: "每天拉取时间", action: nil, keyEquivalent: "")
        hourItem.submenu = hourMenu
        menu.addItem(hourItem)

        menu.addItem(.separator())

        let configItem = NSMenuItem(title: "打开关注列表…", action: #selector(menuOpenConfig), keyEquivalent: "")
        configItem.target = self
        menu.addItem(configItem)

        let folderItem = NSMenuItem(title: "打开数据文件夹", action: #selector(menuOpenFolder), keyEquivalent: "")
        folderItem.target = self
        menu.addItem(folderItem)

        let cacheItem = NSMenuItem(title: "图片缓存 \(store.cacheText) · 清空", action: #selector(menuClearCache), keyEquivalent: "")
        cacheItem.target = self
        menu.addItem(cacheItem)

        let resetItem = NSMenuItem(title: "重置排序与偏好", action: #selector(menuResetPrefs), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)

        let authItem = NSMenuItem(title: "GitHub：\(Auth.source)", action: nil, keyEquivalent: "")
        authItem.isEnabled = false
        menu.addItem(authItem)

        if case .failed(let text) = store.phase {
            let errorItem = NSMenuItem(title: "上次失败：\(text)", action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        }

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 OpenFeed", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        if let anchor {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.minY - 2), in: anchor)
        } else if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 2), in: button)
        }
    }

    @objc private func menuRefresh() {
        Task { await refresh(manual: true) }
    }

    @objc private func menuMarkRead() {
        store.markAllVisited()
        render()
    }

    @objc private func menuToggleAutoStart() {
        let enable = !LoginItem.isEnabled
        if enable { LoginItem.enable() } else { LoginItem.disable() }
        UserDefaults.standard.set(enable, forKey: "autoStart")
    }

    @objc private func menuSetHour(_ sender: NSMenuItem) {
        store.setHour(sender.tag)
    }

    @objc private func menuClearCache() {
        store.clearCache()
    }

    @objc private func menuResetPrefs() {
        store.resetPreferences()
    }

    @objc private func menuOpenConfig() {
        NSWorkspace.shared.open(FeedConfig.fileURL)
    }

    @objc private func menuOpenFolder() {
        NSWorkspace.shared.open(Paths.root)
    }

    // MARK: - 定时

    private func observe() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.popover.performClose(nil)
            self?.preview.hide()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.tick()
        }
        guard !store.phase.isRunning else { return }
        if Scheduler.isDue(lastSuccess: store.snapshot.lastSuccessAt, hour: store.config.hour) {
            Task { await refresh(manual: false) }
        }
    }

    private func refresh(manual: Bool) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await store.refresh(manual: manual)
        render()
    }
}

import AppKit

let application = NSApplication.shared

// 自检口子：不起菜单栏，自己推着 runloop 把异步活跑完再退出。
// （直接 run() 再等，主线程会卡在事件循环里，Task 永远轮不到。）
if Probe.isRequested {
    application.setActivationPolicy(.prohibited)
    let store = MainActor.assumeIsolated { FeedStore() }
    let done = DispatchSemaphore(value: 0)
    Task { @MainActor in
        await Probe.run(store: store)
        done.signal()
    }
    while done.wait(timeout: .now() + 0.05) == .timedOut {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    exit(0)
}

// 只允许一个实例：自启拉起来的那个已经在跑时，别再开第二个菜单栏格子。
if CommandLine.arguments.count == 1 {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: "app.openfeed.macos")
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if !others.isEmpty { exit(0) }
}

let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()

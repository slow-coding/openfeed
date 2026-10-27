import AppKit

/// 开机自启：写一个 LaunchAgent（`~/Library/LaunchAgents`）。
/// 不用 SMAppService——ad-hoc 签名的 app 和系统记录对不上会被拒；LaunchAgent 只要路径对就稳。
enum LoginItem {
    static let label = "app.openfeed.macos"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var appPath: String { "/Applications/OpenFeed.app" }
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    @discardableResult
    static func enable() -> Bool {
        let executable = "\(appPath)/Contents/MacOS/OpenFeed"
        guard FileManager.default.fileExists(atPath: executable) else { return false }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array><string>\(executable)</string></array>
            <key>RunAtLoad</key><true/>
            <key>ProcessType</key><string>Interactive</string>
            <key>LimitLoadToSessionType</key><string>Aqua</string>
        </dict>
        </plist>
        """
        try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard (try? plist.data(using: .utf8)?.write(to: plistURL, options: .atomic)) != nil else { return false }
        reload()
        return true
    }

    static func disable() {
        run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    private static func reload() {
        run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    private static func run(_ tool: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

/// 状态栏那枚图标：三根高低不同的圆角竖条，模板色，深浅菜单栏都读得出来。
enum StatusIcon {
    static func image(height: CGFloat = 15) -> NSImage {
        let size = NSSize(width: 17, height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            let barWidth: CGFloat = 2.6
            let heights: [CGFloat] = [6.5, 11.5, 8.5]
            let gap: CGFloat = 2.1
            let total = barWidth * 3 + gap * 2
            let startX = (size.width - total) / 2
            for (index, barHeight) in heights.enumerated() {
                let rect = NSRect(
                    x: startX + CGFloat(index) * (barWidth + gap),
                    y: (height - barHeight) / 2,
                    width: barWidth,
                    height: barHeight
                )
                NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

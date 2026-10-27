import SwiftUI
import AppKit

/// 只有这里写数字。面板宽度、内距、缩略图、字号都从这几个常量推出来。
enum T {
    static let width: CGFloat = 460
    static let height: CGFloat = 640
    static let pad: CGFloat = 16
    static let contentWidth: CGFloat = width - pad * 2

    static let icon: CGFloat = 20
    static let rowGap: CGFloat = 10
    static let rowTop: CGFloat = 9
    static let rowBottom: CGFloat = 9
    static let textColumn: CGFloat = contentWidth - icon - rowGap

    static let titleSize: CGFloat = 13
    static let summarySize: CGFloat = 11.5
    static let metaSize: CGFloat = 10.5
    static let sectionSize: CGFloat = 11

    static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua])
            return match == .darkAqua ? dark : light
        })
    }

    static let accent = dynamic(
        dark: NSColor(srgbRed: 0.55, green: 0.65, blue: 1.00, alpha: 1),
        light: NSColor(srgbRed: 0.24, green: 0.36, blue: 0.86, alpha: 1)
    )

    static let hairline = dynamic(
        dark: NSColor.white.withAlphaComponent(0.10),
        light: NSColor.black.withAlphaComponent(0.09)
    )

    static let rowHover = dynamic(
        dark: NSColor.white.withAlphaComponent(0.055),
        light: NSColor.black.withAlphaComponent(0.045)
    )

    static let tile = dynamic(
        dark: NSColor.white.withAlphaComponent(0.07),
        light: NSColor.black.withAlphaComponent(0.05)
    )

    /// 兴趣线的点。同一档亮度，靠色相区分，不抢主色。
    static func lane(_ name: String) -> Color {
        switch name {
        case "上下文记忆": return dynamic(dark: NSColor(srgbRed: 0.36, green: 0.80, blue: 0.76, alpha: 1),
                                    light: NSColor(srgbRed: 0.10, green: 0.53, blue: 0.50, alpha: 1))
        case "记忆图谱": return dynamic(dark: NSColor(srgbRed: 0.72, green: 0.63, blue: 0.98, alpha: 1),
                                    light: NSColor(srgbRed: 0.44, green: 0.32, blue: 0.79, alpha: 1))
        case "Agent": return dynamic(dark: NSColor(srgbRed: 0.50, green: 0.70, blue: 1.00, alpha: 1),
                                     light: NSColor(srgbRed: 0.15, green: 0.42, blue: 0.80, alpha: 1))
        case "编程智能体": return dynamic(dark: NSColor(srgbRed: 0.55, green: 0.85, blue: 0.58, alpha: 1),
                                     light: NSColor(srgbRed: 0.16, green: 0.51, blue: 0.24, alpha: 1))
        case "生成式界面": return dynamic(dark: NSColor(srgbRed: 0.98, green: 0.60, blue: 0.75, alpha: 1),
                                     light: NSColor(srgbRed: 0.72, green: 0.20, blue: 0.42, alpha: 1))
        case "动效视觉": return dynamic(dark: NSColor(srgbRed: 0.99, green: 0.72, blue: 0.42, alpha: 1),
                                    light: NSColor(srgbRed: 0.72, green: 0.41, blue: 0.06, alpha: 1))
        case "关注项目": return dynamic(dark: NSColor(srgbRed: 0.66, green: 0.72, blue: 0.85, alpha: 1),
                                    light: NSColor(srgbRed: 0.35, green: 0.42, blue: 0.55, alpha: 1))
        default: return Color.secondary
        }
    }
}

extension Int {
    /// 12400 → 12.4k，摆进小字里不跳宽。
    var starText: String {
        if self >= 100_000 { return "\(self / 1000)k" }
        if self >= 10_000 { return String(format: "%.0fk", Double(self) / 1000) }
        if self >= 1_000 { return String(format: "%.1fk", Double(self) / 1000) }
        return "\(self)"
    }
}

extension Date {
    /// 刚刚 / 3 小时前 / 昨天 / 5 天前 / 10月12日
    var agoText: String {
        let seconds = Date().timeIntervalSince(self)
        if seconds < 90 { return "刚刚" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600)) 小时前" }
        let days = Int(seconds / 86_400)
        if days == 1 { return "昨天" }
        if days < 7 { return "\(days) 天前" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = Calendar.current.isDate(self, equalTo: Date(), toGranularity: .year)
            ? "M月d日" : "yyyy年M月d日"
        return formatter.string(from: self)
    }

    /// 今天 / 昨天 / 10月25日
    var dayHeader: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return "今天" }
        if calendar.isDateInYesterday(self) { return "昨天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: self)
    }
}

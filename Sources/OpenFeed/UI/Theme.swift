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

    /// 打分的星：亮黄实心（蓝的看起来像链接，不像评价）
    static let star = dynamic(
        dark: NSColor(srgbRed: 1.00, green: 0.84, blue: 0.04, alpha: 1),
        light: NSColor(srgbRed: 0.95, green: 0.65, blue: 0.00, alpha: 1)
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

    /// 兴趣线的点。同一档亮度，靠色相区分，不抢主色；颜色跟着线名走，不认具体叫什么。
    static func lane(_ name: String) -> Color {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        let pair = lanePalette[Int(hash % UInt64(lanePalette.count))]
        return dynamic(dark: pair.dark, light: pair.light)
    }

    private static let lanePalette: [(dark: NSColor, light: NSColor)] = [
        (NSColor(srgbRed: 0.36, green: 0.80, blue: 0.76, alpha: 1),
         NSColor(srgbRed: 0.10, green: 0.53, blue: 0.50, alpha: 1)),
        (NSColor(srgbRed: 0.72, green: 0.63, blue: 0.98, alpha: 1),
         NSColor(srgbRed: 0.44, green: 0.32, blue: 0.79, alpha: 1)),
        (NSColor(srgbRed: 0.50, green: 0.70, blue: 1.00, alpha: 1),
         NSColor(srgbRed: 0.15, green: 0.42, blue: 0.80, alpha: 1)),
        (NSColor(srgbRed: 0.55, green: 0.85, blue: 0.58, alpha: 1),
         NSColor(srgbRed: 0.16, green: 0.51, blue: 0.24, alpha: 1)),
        (NSColor(srgbRed: 0.98, green: 0.60, blue: 0.75, alpha: 1),
         NSColor(srgbRed: 0.72, green: 0.20, blue: 0.42, alpha: 1)),
        (NSColor(srgbRed: 0.99, green: 0.72, blue: 0.42, alpha: 1),
         NSColor(srgbRed: 0.72, green: 0.41, blue: 0.06, alpha: 1)),
        (NSColor(srgbRed: 0.66, green: 0.72, blue: 0.85, alpha: 1),
         NSColor(srgbRed: 0.35, green: 0.42, blue: 0.55, alpha: 1)),
        (NSColor(srgbRed: 0.93, green: 0.60, blue: 0.60, alpha: 1),
         NSColor(srgbRed: 0.68, green: 0.24, blue: 0.24, alpha: 1)),
    ]
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
        if seconds < 90 { return L.t("刚刚", "just now") }
        if seconds < 3_600 {
            let n = Int(seconds / 60)
            return L.t("\(n) 分钟前", "\(n) min ago")
        }
        if seconds < 86_400 {
            let n = Int(seconds / 3_600)
            return L.t("\(n) 小时前", "\(n) h ago")
        }
        let days = Int(seconds / 86_400)
        if days == 1 { return L.t("昨天", "yesterday") }
        if days < 7 { return L.t("\(days) 天前", "\(days) d ago") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L.isEN ? "en_US_POSIX" : "zh_Hans_CN")
        let sameYear = Calendar.current.isDate(self, equalTo: Date(), toGranularity: .year)
        formatter.dateFormat = L.isEN ? (sameYear ? "MMM d" : "MMM d, yyyy")
                                      : (sameYear ? "M月d日" : "yyyy年M月d日")
        return formatter.string(from: self)
    }

    /// 今天 / 昨天 / 10月25日
    var dayHeader: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return L.t("今天", "Today") }
        if calendar.isDateInYesterday(self) { return L.t("昨天", "Yesterday") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L.isEN ? "en_US_POSIX" : "zh_Hans_CN")
        formatter.dateFormat = L.isEN ? "MMM d, EEEE" : "M月d日 EEEE"
        return formatter.string(from: self)
    }
}

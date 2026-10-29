import Foundation

/// 界面文案：中英两边写在一起，语言跟着 config 的 `uiLang`（"en" / "zh"）；
/// 不配就看系统语言。没有 .lproj 那一套：文案就在用它的地方，改一句话不用找两份文件。
enum L {
    private static var cached: Bool?

    static var isEN: Bool {
        if let cached { return cached }
        // 环境变量给截图与自检用，优先于 config。
        let override = ProcessInfo.processInfo.environment["OPENFEED_LANG"]?.lowercased() ?? ""
        let configured = override.isEmpty ? FeedConfig.load().uiLang.lowercased() : override
        let resolved: Bool
        if configured.hasPrefix("en") {
            resolved = true
        } else if configured.hasPrefix("zh") {
            resolved = false
        } else {
            resolved = !(Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("zh")
        }
        cached = resolved
        return resolved
    }

    /// 菜单里改了语言要立刻生效：缓存清掉，下一次取文案就按新的来。
    static func reset() { cached = nil }

    static func t(_ zh: String, _ en: String) -> String { isEN ? en : zh }

    /// 线名是存在数据里的（关注项目 / 讨论是 app 自己生成的两条），显示时才翻。
    static func lane(_ name: String) -> String {
        switch name {
        case "关注项目": return t("关注项目", "Releases")
        case "讨论": return t("讨论", "Discussions")
        default: return name
        }
    }
}

import AppKit

/// 界面语言：跟随系统 / 中文 / English。
/// 所有窗口都是代码构建的：语言切换后由 AppDelegate 重建已存在的设置类窗口即时生效；
/// 菜单栏菜单每次打开都重建，天然跟随
enum AppLanguage: String, CaseIterable {
    case system
    case zh
    case en

    var index: Int { AppLanguage.allCases.firstIndex(of: self)! }
}

enum L10n {
    static var isEnglish: Bool {
        switch AppSettings.shared.language {
        case .en:
            return true
        case .zh:
            return false
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            return !preferred.lowercased().hasPrefix("zh")
        }
    }

    static func t(_ zh: String, _ en: String) -> String { isEnglish ? en : zh }
}

/// 词条函数：L("中文", "English")
func L(_ zh: String, _ en: String) -> String { L10n.t(zh, en) }

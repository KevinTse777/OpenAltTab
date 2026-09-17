import AppKit

enum CardSize: String, CaseIterable {
    case small, medium, large

    var thumbSize: NSSize {
        switch self {
        case .small: return NSSize(width: 176, height: 110)
        case .medium: return NSSize(width: 256, height: 160)
        case .large: return NSSize(width: 336, height: 210)
        }
    }

    var index: Int { CardSize.allCases.firstIndex(of: self)! }
}

enum Theme: String, CaseIterable {
    case auto, light, dark

    var appearance: NSAppearance? {
        switch self {
        case .auto: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    var index: Int { Theme.allCases.firstIndex(of: self)! }
}

enum Scope: String, CaseIterable {
    case allApps
    case activeApp

    var index: Int { Scope.allCases.firstIndex(of: self)! }
}

/// 面板出现在哪块屏幕
enum PanelScreen: String, CaseIterable {
    case targetWindow
    case mouse

    var index: Int { PanelScreen.allCases.firstIndex(of: self)! }
}

/// 面板皮肤
enum Skin: String, CaseIterable {
    case macOSSkin   // 毛玻璃 HUD（跟随系统浅/深色）
    case windows10   // Windows 10 风格：深灰扁平面板 + 蓝色选中框

    var index: Int { Skin.allCases.firstIndex(of: self)! }
}

/// 卡片内容样式（对齐上游 Pro 的 appearanceStyle，本项目免费）
enum CardStyle: String, CaseIterable {
    case thumbnails  // 缩略图 + 标题
    case appIcons    // 大应用图标，无标题
    case titles      // 仅标题条

    var index: Int { CardStyle.allCases.firstIndex(of: self)! }
}

/// 窗口列表排序
enum WindowOrder: String, CaseIterable {
    case recentlyFocused
    case alphabetical

    var index: Int { WindowOrder.allCases.firstIndex(of: self)! }
}

/// 松开触发键（⌥ 或 ^）的行为
enum ReleaseAction: String, CaseIterable {
    case focus   // 立即切换（经典 ⌥Tab 体验）
    case hold    // 保持面板：回车确认、Esc 取消
    case search  // 进入搜索模式

    var index: Int { ReleaseAction.allCases.firstIndex(of: self)! }
}

/// 标题栏应用图标边长（pt）
enum IconSize: String, CaseIterable {
    case small, medium, large

    var side: CGFloat {
        switch self {
        case .small: return 16
        case .medium: return 20
        case .large: return 26
        }
    }

    var index: Int { IconSize.allCases.firstIndex(of: self)! }
}

/// 窗口标题字号（pt）
enum TitleFontSize: String, CaseIterable {
    case small, medium, large

    var size: CGFloat {
        switch self {
        case .small: return 11
        case .medium: return 12.5
        case .large: return 14
        }
    }

    var index: Int { TitleFontSize.allCases.firstIndex(of: self)! }
}

final class AppSettings {
    static let shared = AppSettings()
    static let changedNotification = Notification.Name("OpenAltTabSettingsChanged")
    static let maxItems = 40

    private let d = UserDefaults.standard

    var cardSize: CardSize {
        get { CardSize(rawValue: d.string(forKey: "cardSize") ?? "") ?? .medium }
        set { d.set(newValue.rawValue, forKey: "cardSize"); notify() }
    }

    var cardStyle: CardStyle {
        get { CardStyle(rawValue: d.string(forKey: "cardStyle") ?? "") ?? .thumbnails }
        set { d.set(newValue.rawValue, forKey: "cardStyle"); notify() }
    }

    /// 按窗口数量自动调整卡片大小（上游 Pro autoSize 免费版）
    var autoSize: Bool {
        get { d.object(forKey: "autoSize") == nil ? false : d.bool(forKey: "autoSize") }
        set { d.set(newValue, forKey: "autoSize"); notify() }
    }

    var theme: Theme {
        get { Theme(rawValue: d.string(forKey: "theme") ?? "") ?? .auto }
        set { d.set(newValue.rawValue, forKey: "theme"); notify() }
    }

    var scope: Scope {
        get { Scope(rawValue: d.string(forKey: "scope") ?? "") ?? .allApps }
        set { d.set(newValue.rawValue, forKey: "scope"); notify() }
    }

    var panelScreen: PanelScreen {
        get { PanelScreen(rawValue: d.string(forKey: "panelScreen") ?? "") ?? .targetWindow }
        set { d.set(newValue.rawValue, forKey: "panelScreen"); notify() }
    }

    var iconSize: IconSize {
        get { IconSize(rawValue: d.string(forKey: "iconSize") ?? "") ?? .medium }
        set { d.set(newValue.rawValue, forKey: "iconSize"); notify() }
    }

    var titleFontSize: TitleFontSize {
        get { TitleFontSize(rawValue: d.string(forKey: "titleFontSize") ?? "") ?? .medium }
        set { d.set(newValue.rawValue, forKey: "titleFontSize"); notify() }
    }

    /// 网格最大行数；0 = 自动（按面板宽度自然排布）
    var maxRows: Int {
        get { d.object(forKey: "maxRows") == nil ? 0 : d.integer(forKey: "maxRows") }
        set { d.set(newValue, forKey: "maxRows"); notify() }
    }

    /// 松开触发键的行为
    var releaseAction: ReleaseAction {
        get { ReleaseAction(rawValue: d.string(forKey: "releaseAction") ?? "") ?? .focus }
        set { d.set(newValue.rawValue, forKey: "releaseAction"); notify() }
    }

    /// 第二组快捷键 ^Tab（Shift+^Tab 反向；⌘Tab 永远让给系统切换器）
    var enableCtrlTab: Bool {
        get { d.object(forKey: "enableCtrlTab") == nil ? false : d.bool(forKey: "enableCtrlTab") }
        set { d.set(newValue, forKey: "enableCtrlTab"); notify() }
    }

    /// 额外触发键规格串（逗号分隔，如 "^⌥Tab,⌥`"），组数不限（上游最多 9 组）
    var extraShortcutsRaw: String {
        get { d.string(forKey: "extraShortcutsRaw") ?? "" }
        set { d.set(newValue, forKey: "extraShortcutsRaw"); notify() }
    }

    var windowOrder: WindowOrder {
        get { WindowOrder(rawValue: d.string(forKey: "windowOrder") ?? "") ?? .recentlyFocused }
        set { d.set(newValue.rawValue, forKey: "windowOrder"); notify() }
    }

    /// 隐藏中的应用（⌘H）是否出现在列表里
    var showHiddenApps: Bool {
        get { d.object(forKey: "showHiddenApps") == nil ? true : d.bool(forKey: "showHiddenApps") }
        set { d.set(newValue, forKey: "showHiddenApps"); notify() }
    }

    /// 无窗口应用排在列表末尾（对齐上游 showAtTheEnd）
    var showWindowlessApps: Bool {
        get { d.object(forKey: "showWindowlessApps") == nil ? true : d.bool(forKey: "showWindowlessApps") }
        set { d.set(newValue, forKey: "showWindowlessApps"); notify() }
    }

    /// 把浏览器的标签容器窗口拆成每个标签一张卡片（对齐上游 showTabsAsWindows）
    var showTabsAsWindows: Bool {
        get { d.object(forKey: "showTabsAsWindows") == nil ? false : d.bool(forKey: "showTabsAsWindows") }
        set { d.set(newValue, forKey: "showTabsAsWindows"); notify() }
    }

    /// 仅显示当前桌面（Space）的窗口（对齐上游 spacesToShow）
    var showAllSpaces: Bool {
        get { d.object(forKey: "showAllSpaces") == nil ? true : d.bool(forKey: "showAllSpaces") }
        set { d.set(newValue, forKey: "showAllSpaces"); notify() }
    }

    /// 界面语言
    var language: AppLanguage {
        get { AppLanguage(rawValue: d.string(forKey: "language") ?? "") ?? .system }
        set { d.set(newValue.rawValue, forKey: "language"); notify() }
    }

    var skin: Skin {
        get { Skin(rawValue: d.string(forKey: "skin") ?? "") ?? .macOSSkin }
        set { d.set(newValue.rawValue, forKey: "skin"); notify() }
    }

    /// 循环时在目标窗口的真实位置浮出大图预览（对齐上游 PreviewPanel）
    var previewSelectedWindow: Bool {
        get { d.object(forKey: "previewSelectedWindow") == nil ? true : d.bool(forKey: "previewSelectedWindow") }
        set { d.set(newValue, forKey: "previewSelectedWindow"); notify() }
    }

    /// 忽略的应用（bundle identifier 列表，对齐上游 Exceptions 的 ignore 项）
    var ignoredApps: [String] {
        get { d.stringArray(forKey: "ignoredApps") ?? [] }
        set { d.set(newValue, forKey: "ignoredApps"); notify() }
    }

    var showMinimized: Bool {
        get { d.object(forKey: "showMinimized") == nil ? true : d.bool(forKey: "showMinimized") }
        set { d.set(newValue, forKey: "showMinimized"); notify() }
    }

    private func notify() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: AppSettings.changedNotification, object: nil)
        }
    }

    func applyAppearance() {
        NSApp.appearance = theme.appearance
    }
}

func activateOurApp() {
    if #available(macOS 14.0, *) {
        NSApp.activate()
    } else {
        NSApp.activate(ignoringOtherApps: true)
    }
}

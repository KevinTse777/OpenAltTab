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

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

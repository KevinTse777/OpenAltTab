import AppKit
import ApplicationServices

final class WindowItem {
    let app: NSRunningApplication
    let axApp: AXUIElement
    let axWindow: AXUIElement
    /// 用于截图的 CGWindow 编号；个别窗口拿不到时为 nil（显示占位图）
    let cgWindowID: CGWindowID?
    /// CGWindowList 里的实际显示边界（屏幕左上原点坐标系）。
    /// 台前调度会把条目窗口缩小显示：此时它远小于逻辑尺寸，截图必然带倾斜变换
    let cgFrame: CGRect?
    var title: String
    var isMinimized: Bool
    /// 枚举瞬间窗口是否处于全屏（AX "AXFullScreen" 属性；全屏窗口独占一个 Space）
    var isFullscreen: Bool
    /// 枚举瞬间应用是否整体隐藏（状态角标 + 隐藏/显示切换的初始判断）
    let appHidden: Bool
    /// NSScreen 坐标系（左下角为原点）下的窗口位置
    var screenFrame: CGRect?
    var thumbnail: CGImage?

    init(app: NSRunningApplication, axApp: AXUIElement, axWindow: AXUIElement,
         cgWindowID: CGWindowID?, cgFrame: CGRect?, title: String,
         isMinimized: Bool, isFullscreen: Bool, appHidden: Bool, screenFrame: CGRect?) {
        self.app = app
        self.axApp = axApp
        self.axWindow = axWindow
        self.cgWindowID = cgWindowID
        self.cgFrame = cgFrame
        self.title = title.replacingOccurrences(of: "\n", with: " ")
        self.isMinimized = isMinimized
        self.isFullscreen = isFullscreen
        self.appHidden = appHidden
        self.screenFrame = screenFrame
    }

    var appName: String { app.localizedName ?? "窗口" }

    var displayTitle: String { title.isEmpty ? appName : title }

    /// 磁盘缩略图缓存的键：最后所见内容按"应用+标题"跨面板/重启保留。
    /// 无标题窗口不做磁盘缓存（键不稳定）
    var diskKey: String {
        guard !title.isEmpty else { return "" }
        return "\(app.bundleIdentifier ?? appName)|\(title)"
    }
}

/// 私有但多年稳定的 API：把 AXWindow 映射到 CGWindowID，AltTab 等同类工具也在使用
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ window: AXUIElement, _ out: UnsafeMutablePointer<CGWindowID>) -> AXError

enum WindowEnumerator {
    private static var appRecency: [pid_t: Double] = [:]
    private static var observerInstalled = false

    static func installRecencyObserver() {
        guard !observerInstalled else { return }
        observerInstalled = true
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                appRecency[app.processIdentifier] = Date.timeIntervalSinceReferenceDate
            }
        }
    }

    /// 枚举所有可选窗口，按"最近使用"排序：前台应用最前，其余按激活时间倒序
    static func fetch(settings: AppSettings) -> [WindowItem] {
        installRecencyObserver()
        let selfPID = ProcessInfo.processInfo.processIdentifier

        var apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != selfPID
        }
        if settings.scope == .activeApp, let front = NSWorkspace.shared.frontmostApplication {
            apps = apps.filter { $0.processIdentifier == front.processIdentifier }
        }

        let activePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        apps.sort { a, b in
            if a.processIdentifier == activePID { return true }
            if b.processIdentifier == activePID { return false }
            let ta = appRecency[a.processIdentifier] ?? 0
            let tb = appRecency[b.processIdentifier] ?? 0
            if ta != tb { return ta > tb }
            return a.processIdentifier < b.processIdentifier
        }

        // CGWindowList 实际显示边界：台前调度条目窗口会明显小于逻辑尺寸，用于识别"必斜"窗口
        var cgFrames: [CGWindowID: CGRect] = [:]
        if let cgList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
            for w in cgList {
                guard w[kCGWindowLayer as String] as? Int == 0 else { continue }
                let id = w[kCGWindowNumber as String] as? Int ?? -1
                guard id >= 0,
                      let b = w[kCGWindowBounds as String] as? [String: Any],
                      let rect = CGRect(dictionaryRepresentation: b as CFDictionary) else { continue }
                cgFrames[CGWindowID(id)] = rect
            }
        }

        var result: [WindowItem] = []
        result.reserveCapacity(24)
        for app in apps {
            if !settings.showHiddenApps && app.isHidden { continue }
            if let bid = app.bundleIdentifier, settings.ignoredApps.contains(bid) { continue }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            // 单个应用无响应时最多阻塞 0.35s，避免卡住整个切换器
            AXUIElementSetMessagingTimeout(axApp, 0.35)
            var list: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &list) == .success,
                  let axWindows = list as? [AXUIElement] else { continue }
            for axw in axWindows {
                if let item = describe(app: app, axApp: axApp, axWindow: axw,
                                       settings: settings, cgFrames: cgFrames) {
                    result.append(item)
                    if result.count >= AppSettings.maxItems { return result }
                }
            }
        }
        if settings.windowOrder == .alphabetical {
            result.sort { a, b in
                let an = a.appName.lowercased(), bn = b.appName.lowercased()
                if an != bn { return an < bn }
                return a.title.lowercased() < b.title.lowercased()
            }
        }
        return result
    }

    private static func describe(app: NSRunningApplication, axApp: AXUIElement,
                                 axWindow: AXUIElement, settings: AppSettings,
                                 cgFrames: [CGWindowID: CGRect]) -> WindowItem? {
        if let subrole = axString(axWindow, kAXSubroleAttribute),
           subrole == kAXSystemDialogSubrole || subrole == kAXSystemFloatingWindowSubrole
           || subrole == "AXDesktop" {
            return nil
        }
        AXUIElementSetMessagingTimeout(axWindow, 0.35)
        let title = axString(axWindow, kAXTitleAttribute) ?? ""
        let minimized = axBool(axWindow, kAXMinimizedAttribute)
        // 与上游一致：直接读 AX 全屏标志；部分应用不响应该属性时按 false 处理
        let fullscreen = axBool(axWindow, "AXFullScreen")
        if minimized && !settings.showMinimized { return nil }

        let pos = axPoint(axWindow, kAXPositionAttribute)
        let size = axSize(axWindow, kAXSizeAttribute)
        if let s = size, s.width < 48 || s.height < 32, !minimized { return nil }

        var cgID: CGWindowID = 0
        let hasCGID = _AXUIElementGetWindow(axWindow, &cgID) == .success

        // 幽灵窗口规则：AX 报告了 CG 编号但 CGWindowList layer 0 里查无此窗 → 不是真实可选窗口。
        // 真实用户窗口必然在 layer 0（最小化和其他 Space 的窗口也在）；访达桌面等系统窗口会在这里漏馅
        if hasCGID && !minimized && cgFrames[cgID] == nil { return nil }

        let screenFrame: CGRect? = {
            guard let p = pos, let s = size, s.width > 0, s.height > 0 else { return nil }
            let primaryMaxY = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY
                ?? NSScreen.main?.frame.maxY ?? 900
            return CGRect(x: p.x, y: primaryMaxY - p.y - s.height, width: s.width, height: s.height)
        }()

        guard hasCGID || !title.isEmpty || screenFrame != nil else { return nil }

        return WindowItem(app: app, axApp: axApp, axWindow: axWindow,
                          cgWindowID: hasCGID ? cgID : nil,
                          cgFrame: hasCGID ? cgFrames[cgID] : nil,
                          title: title, isMinimized: minimized, isFullscreen: fullscreen,
                          appHidden: app.isHidden, screenFrame: screenFrame)
    }

    // MARK: - 前台窗口摘要（CacheWarmer 预热用）

    struct FrontWindowInfo {
        let cgID: CGWindowID
        let cgFrame: CGRect?
        let axSize: CGSize?
        let diskKey: String
    }

    /// 应用当前最前面的窗口信息（AX 窗口序即 z 序，第一个就是最前面的）
    static func frontWindowSummary(for app: NSRunningApplication) -> FrontWindowInfo? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.35)
        var list: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &list) == .success,
              let axWindows = list as? [AXUIElement], let axw = axWindows.first else { return nil }
        AXUIElementSetMessagingTimeout(axw, 0.35)
        var cgID: CGWindowID = 0
        guard _AXUIElementGetWindow(axw, &cgID) == .success else { return nil }
        let title = (axString(axw, kAXTitleAttribute) ?? "").replacingOccurrences(of: "\n", with: " ")
        let size = axSize(axw, kAXSizeAttribute)
        var cgFrame: CGRect?
        if let cgList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
            for w in cgList {
                guard w[kCGWindowNumber as String] as? Int == Int(cgID),
                      let b = w[kCGWindowBounds as String] as? [String: Any] else { continue }
                cgFrame = CGRect(dictionaryRepresentation: b as CFDictionary)
                break
            }
        }
        let key = title.isEmpty ? "" : "\(app.bundleIdentifier ?? app.localizedName ?? "app")|\(title)"
        return FrontWindowInfo(cgID: cgID, cgFrame: cgFrame, axSize: size, diskKey: key)
    }

    private static func axString(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func axBool(_ el: AXUIElement, _ attr: String) -> Bool {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return false }
        if let b = v as? Bool { return b }
        guard let cf = v, CFGetTypeID(cf) == CFBooleanGetTypeID() else { return false }
        return CFBooleanGetValue(unsafeDowncast(cf, to: CFBoolean.self))
    }

    private static func axPoint(_ el: AXUIElement, _ attr: String) -> CGPoint? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        guard let cf = v, CFGetTypeID(cf) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        guard AXValueGetValue(unsafeDowncast(cf, to: AXValue.self), .cgPoint, &p) else { return nil }
        return p
    }

    private static func axSize(_ el: AXUIElement, _ attr: String) -> CGSize? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        guard let cf = v, CFGetTypeID(cf) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(cf, to: AXValue.self), .cgSize, &s) else { return nil }
        return s
    }
}

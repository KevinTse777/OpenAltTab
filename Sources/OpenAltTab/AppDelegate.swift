import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()
    let warmer = CacheWarmer()
    var statusItem: NSStatusItem?
    var permissionsWindow: PermissionsWindow?
    var prefsWindow: PrefsWindow?
    var pollTimer: Timer?
    var watchdogTimer: Timer?
    /// 启动后的首次自动注册只执行一次：巡检再次弹引导窗口时不重复 reset/request
    private var autoRegisterDone = false
    /// 语言变化检测：切换后重建设置类窗口让新词条生效
    private var lastLanguage: AppLanguage = AppSettings.shared.language

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.shared.applyAppearance()
        coordinator.start()
        warmer.start()
        setupStatusItem()

        if !Permissions.accessibilityGranted || !Permissions.screenRecordingGranted {
            showPermissionFlow()
        }
        startPermissionWatchdog()

        NotificationCenter.default.addObserver(forName: AppSettings.changedNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            AppSettings.shared.applyAppearance()
            self?.coordinator.refreshAppearance()
            self?.rebuildWindowsIfLanguageChanged()
        }
    }

    /// 语言切换后重建已打开的设置类窗口（面板网格文本由下次刷新自然带出）
    private func rebuildWindowsIfLanguageChanged() {
        guard AppSettings.shared.language != lastLanguage else { return }
        lastLanguage = AppSettings.shared.language
        if let w = permissionsWindow, w.win.isVisible {
            permissionsWindow = PermissionsWindow()
            permissionsWindow?.show()
        } else {
            permissionsWindow = nil
        }
        if let w = prefsWindow, w.win.isVisible {
            prefsWindow = PrefsWindow()
            prefsWindow?.show()
        } else {
            prefsWindow = nil
        }
    }

    private func showPermissionFlow() {
        autoRegisterIfNeeded()
        if permissionsWindow == nil { permissionsWindow = PermissionsWindow() }
        permissionsWindow?.show()
        if pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.pollPermissions()
            }
        }
    }

    /// 自动按需注册：缺哪个权限就只触发哪个的系统弹窗，用户不必自己找按钮
    private func autoRegisterIfNeeded() {
        guard !autoRegisterDone else { return }
        autoRegisterDone = true
        if !Permissions.accessibilityGranted {
            Permissions.promptAccessibilityRegistration()
        }
        if !Permissions.screenRecordingGranted {
            Permissions.resetScreenRecordingRegistration()
            Permissions.requestScreenRecording()
        }
    }

    /// 常驻低速巡检：权限被移除（如用户删掉旧授权条目）时自动弹回引导窗口并重新触发按需注册，
    /// 全程无需重启 App
    private func startPermissionWatchdog() {
        guard watchdogTimer == nil else { return }
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let missing = !Permissions.accessibilityGranted || !Permissions.screenRecordingGranted
            guard missing else { return }
            if self.pollTimer == nil || self.permissionsWindow?.win.isVisible != true {
                self.showPermissionFlow()
            }
        }
    }

    private func pollPermissions() {
        permissionsWindow?.refresh()
        if Permissions.accessibilityGranted { coordinator.start() }
        if Permissions.accessibilityGranted && Permissions.screenRecordingGranted {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    // MARK: - CLI（URL scheme：open "openalttab://动作"）

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handleCLI(url: url) }
    }

    private func handleCLI(url: URL) {
        let host = (url.host ?? "").lowercased()
        let arg = url.pathComponents.count > 1 ? url.pathComponents[1] : nil
        switch host {
        case "next":
            coordinator.activateRelative(1)
        case "previous":
            coordinator.activateRelative(-1)
        case "show":
            coordinator.showOverlay()
        case "hide":
            coordinator.cancelOverlay()
        case "list":
            coordinator.dumpWindowList()
        case "activate":
            if let arg, let n = Int(arg) {
                coordinator.activate(index: n)
            } else {
                NSSound.beep()
            }
        default:
            NSSound.beep()
        }
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle.angled",
                                     accessibilityDescription: "OpenAltTab")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private var launchAtLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @objc private func showPermissions(_ sender: Any?) {
        if permissionsWindow == nil { permissionsWindow = PermissionsWindow() }
        permissionsWindow?.show()
    }

    @objc private func showPreferences(_ sender: Any?) {
        if prefsWindow == nil { prefsWindow = PrefsWindow() }
        prefsWindow?.show()
    }

    @objc private func clearThumbCache(_ sender: Any?) {
        WindowCapture.clearAllCaches()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
    }

    @objc private func showAbout(_ sender: Any?) {
        activateOurApp()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "OpenAltTab",
            .applicationVersion: version,
            .version: version,
            .credits: NSAttributedString(string: L("Windows 风格 ⌥Tab 窗口切换器\n参考 AltTab (alt-tab.xyz) 自研实现，全部功能免费",
                                                    "A Windows-style ⌥Tab window switcher\nA free alternative to AltTab (alt-tab.xyz)")),
        ])
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let axOK = Permissions.accessibilityGranted
        let scrOK = Permissions.screenRecordingGranted
        let perm = NSMenuItem(title: L("辅助功能 \(axOK ? "✅" : "❌")　屏幕录制 \(scrOK ? "✅" : "❌")",
                                      "Accessibility \(axOK ? "✅" : "❌")　Screen Recording \(scrOK ? "✅" : "❌")"),
                              action: nil, keyEquivalent: "")
        perm.isEnabled = false
        menu.addItem(perm)
        if !axOK || !scrOK {
            let grant = NSMenuItem(title: L("打开权限设置…", "Open Permission Settings…"),
                                   action: #selector(showPermissions(_:)), keyEquivalent: "")
            menu.addItem(grant)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("偏好设置…", "Preferences…"), action: #selector(showPreferences(_:)), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: L("清除缩略图缓存", "Clear Thumbnail Cache"), action: #selector(clearThumbCache(_:)), keyEquivalent: ""))
        let login = NSMenuItem(title: L("登录时启动", "Launch at Login"),
                               action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        login.state = launchAtLoginEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: L("关于 OpenAltTab", "About OpenAltTab"), action: #selector(showAbout(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("退出 OpenAltTab", "Quit OpenAltTab"), action: #selector(quitApp(_:)), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
    }
}

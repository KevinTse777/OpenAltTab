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
                                               object: nil, queue: .main) { _ in
            AppSettings.shared.applyAppearance()
        }
    }

    private func showPermissionFlow() {
        if permissionsWindow == nil { permissionsWindow = PermissionsWindow() }
        permissionsWindow?.show()
        if pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.pollPermissions()
            }
        }
    }

    /// 常驻低速巡检：权限被移除（如用户删掉旧授权条目）时自动弹回引导窗口，
    /// 配合"重新注册到系统"按钮，全程无需重启 App
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
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "OpenAltTab",
            .applicationVersion: "1.0.0",
            .version: "1.0.0",
            .credits: NSAttributedString(string: "Windows 风格 ⌥Tab 窗口切换器\n参考 AltTab (alt-tab.xyz) 自研实现，全部功能免费"),
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
        let perm = NSMenuItem(title: "辅助功能 \(axOK ? "✅" : "❌")　屏幕录制 \(scrOK ? "✅" : "❌")",
                              action: nil, keyEquivalent: "")
        perm.isEnabled = false
        menu.addItem(perm)
        if !axOK || !scrOK {
            let grant = NSMenuItem(title: "打开权限设置…",
                                   action: #selector(showPermissions(_:)), keyEquivalent: "")
            menu.addItem(grant)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "偏好设置…", action: #selector(showPreferences(_:)), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "清除缩略图缓存", action: #selector(clearThumbCache(_:)), keyEquivalent: ""))
        let login = NSMenuItem(title: "登录时启动",
                               action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        login.state = launchAtLoginEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "关于 OpenAltTab", action: #selector(showAbout(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 OpenAltTab", action: #selector(quitApp(_:)), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
    }
}

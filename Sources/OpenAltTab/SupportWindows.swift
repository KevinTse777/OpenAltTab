import AppKit

/// 权限引导窗口：检测"辅助功能"和"屏幕录制"，授权后自动关闭
final class PermissionsWindow {
    let win: NSWindow
    private let axStatus = NSTextField(labelWithString: "")
    private let scrStatus = NSTextField(labelWithString: "")

    init() {
        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 280),
                       styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = L("OpenAltTab 需要权限", "OpenAltTab Needs Permissions")

        let title = NSTextField(labelWithString: L("首次使用需要授予两项系统权限",
                                                    "Grant two system permissions to get started"))
        title.font = NSFont.boldSystemFont(ofSize: 15)

        axStatus.font = NSFont.systemFont(ofSize: 12)
        scrStatus.font = NSFont.systemFont(ofSize: 12)

        let axBtn = NSButton(title: L("打开系统设置", "Open System Settings"), target: self, action: #selector(openAX))
        axBtn.bezelStyle = .rounded
        let scrBtn = NSButton(title: L("打开系统设置", "Open System Settings"), target: self, action: #selector(openScr))
        scrBtn.bezelStyle = .rounded

        // App 重新编译/移动后签名变化，旧授权条目失效；点此按需重新登记缺失项，无需重启
        let reRegisterBtn = NSButton(title: L("重新注册缺失的权限（重新编译 / 移动 App 后点这里）",
                                              "Re-register missing permissions (after rebuilding / moving the app)"),
                                     target: self, action: #selector(reRegister))
        reRegisterBtn.bezelStyle = .rounded
        reRegisterBtn.keyEquivalent = "\r"
        reRegisterBtn.controlSize = .large

        // 屏幕录制授权与辅助功能不同：开关打开后必须重启进程才能拿到权限
        let restartBtn = NSButton(title: L("重启 OpenAltTab（屏幕录制授权需重启才生效）",
                                            "Restart OpenAltTab (screen recording requires a restart)"),
                                  target: self, action: #selector(restartApp))
        restartBtn.bezelStyle = .rounded

        let note = NSTextField(wrappingLabelWithString: L(
            "用法：点\"重新注册\"（只处理缺失项）→ 系统弹窗确认 → 在列表里打开开关。\n辅助功能即时生效；屏幕录制必须重启 App（点\"重启 OpenAltTab\"按钮）才生效。\n若弹窗仍不出现，点\"在访达中显示\"把 App 拖进列表。",
            "How to: click \"Re-register\" (missing items only) → confirm the system prompt → turn on the toggle in the list.\nAccessibility takes effect immediately; screen recording requires a restart (use \"Restart OpenAltTab\").\nIf no prompt appears, \"Reveal in Finder\" and drag the app into the list."))
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 14
        grid.columnSpacing = 16
        grid.addRow(with: [makeRow(L("辅助功能", "Accessibility"), axStatus), axBtn])
        grid.addRow(with: [makeRow(L("屏幕录制", "Screen Recording"), scrStatus), scrBtn])
        grid.column(at: 0).xPlacement = .leading

        let revealBtn = NSButton(title: L("在访达中显示 App（弹窗不出现时可手动拖进列表）",
                                          "Reveal app in Finder (drag it into the list if no prompt appears)"),
                                 target: self, action: #selector(revealInFinder))
        revealBtn.bezelStyle = .rounded
        revealBtn.controlSize = .small

        let stack = NSStackView(views: [title, reRegisterBtn, grid, restartBtn, revealBtn, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        win.contentView = stack
        win.setContentSize(stack.fittingSize)
        win.center()
        refresh()
    }

    private func makeRow(_ name: String, _ status: NSTextField) -> NSView {
        let nameField = NSTextField(labelWithString: name)
        nameField.font = NSFont.boldSystemFont(ofSize: 13)
        let stack = NSStackView(views: [nameField, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    func show() {
        activateOurApp()
        refresh()
        win.makeKeyAndOrderFront(nil)
    }

    func close() {
        win.orderOut(nil)
    }

    func refresh() {
        axStatus.stringValue = Permissions.accessibilityGranted
            ? L("✅ 已授权 — 用于监听 ⌥Tab 按键", "✅ Granted — listens for ⌥Tab")
            : L("❌ 未授权 — 用于监听 ⌥Tab 按键", "❌ Not granted — listens for ⌥Tab")
        scrStatus.stringValue = Permissions.screenRecordingGranted
            ? L("✅ 已授权 — 用于生成窗口缩略图", "✅ Granted — renders window thumbnails")
            : L("❌ 未授权 — 用于生成窗口缩略图", "❌ Not granted — renders window thumbnails")
        if Permissions.accessibilityGranted && Permissions.screenRecordingGranted {
            close()
        }
    }

    @objc private func openAX() { Permissions.openAccessibilitySettings() }

    @objc private func openScr() {
        Permissions.requestScreenRecording()
        Permissions.openScreenRecordingSettings()
    }

    /// 重启 App：屏幕录制授权对运行中的进程不生效，必须重启才能拿到
    @objc private func restartApp() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", Bundle.main.bundlePath]
        try? p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }

    /// 在访达里选中 App 包，方便手动拖进系统设置的授权列表
    @objc private func revealInFinder() {
        NSWorkspace.shared.selectFile(Bundle.main.bundlePath, inFileViewerRootedAtPath: "")
    }

    /// 按需重新注册：只处理缺失的权限项，避免把仍然有效的授权也清掉。
    /// 辅助功能缺失 → 弹系统授权窗并打开对应设置；
    /// 屏幕录制缺失 → 先清"已询问过"标记再触发弹窗，只打开屏幕录制面板
    @objc private func reRegister() {
        if !Permissions.accessibilityGranted {
            Permissions.promptAccessibilityRegistration()
            Permissions.openAccessibilitySettings()
        }
        if !Permissions.screenRecordingGranted {
            // 屏幕录制：先清掉"已询问过"标记，否则 CGRequestScreenCaptureAccess 会被静默忽略，
            // 列表里始终不会重新出现条目
            Permissions.resetScreenRecordingRegistration()
            Permissions.requestScreenRecording()
            Permissions.openScreenRecordingSettings()
        }
    }
}

/// 偏好设置窗口
final class PrefsWindow {
    let win: NSWindow
    private weak var ignorePopup: NSPopUpButton?
    private var ignoredListLabel: NSTextField?

    init() {
        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                       styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = L("OpenAltTab 偏好设置", "OpenAltTab Preferences")

        let settings = AppSettings.shared

        let sizePopup = NSPopUpButton()
        [L("小", "Small"), L("中", "Medium"), L("大", "Large")].forEach { sizePopup.addItem(withTitle: $0) }
        sizePopup.selectItem(at: settings.cardSize.index)
        sizePopup.target = self
        sizePopup.action = #selector(sizeChanged(_:))

        let stylePopup = NSPopUpButton()
        [L("缩略图", "Thumbnails"), L("纯应用图标", "App Icons"), L("纯标题", "Titles")].forEach { stylePopup.addItem(withTitle: $0) }
        stylePopup.selectItem(at: settings.cardStyle.index)
        stylePopup.target = self
        stylePopup.action = #selector(cardStyleChanged(_:))

        let themePopup = NSPopUpButton()
        [L("跟随系统", "System"), L("浅色", "Light"), L("深色", "Dark")].forEach { themePopup.addItem(withTitle: $0) }
        themePopup.selectItem(at: settings.theme.index)
        themePopup.target = self
        themePopup.action = #selector(themeChanged(_:))

        let skinPopup = NSPopUpButton()
        [L("macOS 毛玻璃", "macOS HUD"), "Windows 10"].forEach { skinPopup.addItem(withTitle: $0) }
        skinPopup.selectItem(at: settings.skin.index)
        skinPopup.target = self
        skinPopup.action = #selector(skinChanged(_:))

        let previewCheck = NSButton(checkboxWithTitle: L("循环时在目标窗口位置显示大图预览",
                                                          "Show a large preview at the target window's position while cycling"),
                                    target: self, action: #selector(previewChanged(_:)))
        previewCheck.state = settings.previewSelectedWindow ? .on : .off

        let langPopup = NSPopUpButton()
        [L("跟随系统", "System"), "中文", "English"].forEach { langPopup.addItem(withTitle: $0) }
        langPopup.selectItem(at: settings.language.index)
        langPopup.target = self
        langPopup.action = #selector(languageChanged(_:))

        // 忽略应用例外：从运行中的应用列表选择加入
        let ignoreAppPopup = NSPopUpButton()
        ignoreAppPopup.addItem(withTitle: L("选择要忽略的应用…", "Choose an app to ignore…"))
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.localizedName }
            .sorted()
            .forEach { ignoreAppPopup.addItem(withTitle: $0) }
        ignorePopup = ignoreAppPopup
        let addIgnoreBtn = NSButton(title: L("忽略", "Ignore"), target: self, action: #selector(addIgnoredApp(_:)))
        addIgnoreBtn.bezelStyle = .rounded
        let ignoredList = NSTextField(wrappingLabelWithString: L("当前忽略：", "Currently ignored: ")
            + settings.ignoredApps.joined(separator: "、"))
        ignoredList.font = NSFont.systemFont(ofSize: 11)
        ignoredList.textColor = .secondaryLabelColor
        ignoredListLabel = ignoredList
        let clearIgnoreBtn = NSButton(title: L("全部恢复", "Restore All"), target: self, action: #selector(clearIgnoredApps(_:)))
        clearIgnoreBtn.bezelStyle = .rounded
        clearIgnoreBtn.controlSize = .small
        let ignoreRow = NSStackView(views: [ignoreAppPopup, addIgnoreBtn])
        ignoreRow.orientation = .horizontal
        let ignoredRow = NSStackView(views: [ignoredList, clearIgnoreBtn])
        ignoredRow.orientation = .horizontal

        let scopePopup = NSPopUpButton()
        [L("所有应用", "All apps"), L("仅前台应用", "Frontmost app only")].forEach { scopePopup.addItem(withTitle: $0) }
        scopePopup.selectItem(at: settings.scope.index)
        scopePopup.target = self
        scopePopup.action = #selector(scopeChanged(_:))

        let screenPopup = NSPopUpButton()
        [L("目标窗口所在屏幕", "Target window's screen"), L("鼠标所在屏幕", "Mouse's screen")].forEach { screenPopup.addItem(withTitle: $0) }
        screenPopup.selectItem(at: settings.panelScreen.index)
        screenPopup.target = self
        screenPopup.action = #selector(panelScreenChanged(_:))

        let iconPopup = NSPopUpButton()
        [L("小", "Small"), L("中", "Medium"), L("大", "Large")].forEach { iconPopup.addItem(withTitle: $0) }
        iconPopup.selectItem(at: settings.iconSize.index)
        iconPopup.target = self
        iconPopup.action = #selector(iconSizeChanged(_:))

        let fontPopup = NSPopUpButton()
        [L("小", "Small"), L("中", "Medium"), L("大", "Large")].forEach { fontPopup.addItem(withTitle: $0) }
        fontPopup.selectItem(at: settings.titleFontSize.index)
        fontPopup.target = self
        fontPopup.action = #selector(titleFontChanged(_:))

        let rowsPopup = NSPopUpButton()
        [L("自动", "Auto"), L("1 行", "1 row"), L("2 行", "2 rows"), L("3 行", "3 rows"), L("4 行", "4 rows"), L("5 行", "5 rows")].forEach { rowsPopup.addItem(withTitle: $0) }
        rowsPopup.selectItem(at: min(settings.maxRows, rowsPopup.itemArray.count - 1))
        rowsPopup.target = self
        rowsPopup.action = #selector(maxRowsChanged(_:))

        let minCheck = NSButton(checkboxWithTitle: L("显示已最小化的窗口", "Show minimized windows"), target: self, action: #selector(minChanged(_:)))
        minCheck.state = settings.showMinimized ? .on : .off

        let releasePopup = NSPopUpButton()
        [L("立即切换", "Switch on release"), L("保持面板（回车确认）", "Keep panel (press Return)"), L("进入搜索", "Enter search")].forEach { releasePopup.addItem(withTitle: $0) }
        releasePopup.selectItem(at: settings.releaseAction.index)
        releasePopup.target = self
        releasePopup.action = #selector(releaseActionChanged(_:))

        let ctrlTabCheck = NSButton(checkboxWithTitle: L("启用 ^Tab 第二组快捷键（Shift+^Tab 反向循环）",
                                                          "Enable ^Tab as a second shortcut (Shift+^Tab cycles backwards)"),
                                    target: self, action: #selector(ctrlTabChanged(_:)))
        ctrlTabCheck.state = settings.enableCtrlTab ? .on : .off

        let extraField = NSTextField(string: AppSettings.shared.extraShortcutsRaw)
        extraField.placeholderString = L("如 ^⌥Tab, ⌥`（逗号分隔，⌘ 保留给系统）",
                                          "e.g. ^⌥Tab, ⌥` (comma-separated; ⌘ reserved)")
        extraField.target = self
        extraField.action = #selector(extraShortcutsChanged(_:))
        extraField.font = NSFont.systemFont(ofSize: 12)

        let orderPopup = NSPopUpButton()
        [L("最近聚焦优先", "Recently focused first"), L("按名称排序", "Alphabetical")].forEach { orderPopup.addItem(withTitle: $0) }
        orderPopup.selectItem(at: settings.windowOrder.index)
        orderPopup.target = self
        orderPopup.action = #selector(windowOrderChanged(_:))
        let hiddenCheck = NSButton(checkboxWithTitle: L("显示已隐藏应用（⌘H）的窗口", "Show windows of hidden apps (⌘H)"),
                                   target: self, action: #selector(hiddenAppsChanged(_:)))
        hiddenCheck.state = settings.showHiddenApps ? .on : .off

        let windowlessCheck = NSButton(checkboxWithTitle: L("无窗口应用排在列表末尾", "Windowless apps at the end of the list"),
                                       target: self, action: #selector(windowlessChanged(_:)))
        windowlessCheck.state = settings.showWindowlessApps ? .on : .off

        let tabsCheck = NSButton(checkboxWithTitle: L("浏览器标签页拆分为独立卡片（仅保证当前标签的缩略图）",
                                                      "Split browser tabs into separate cards (only the active tab has a thumbnail)"),
                                 target: self, action: #selector(tabsChanged(_:)))
        tabsCheck.state = settings.showTabsAsWindows ? .on : .off

        let spacesCheck = NSButton(checkboxWithTitle: L("仅显示当前桌面（Space）的窗口", "Show windows from the current Space only"),
                                   target: self, action: #selector(spacesChanged(_:)))
        spacesCheck.state = !settings.showAllSpaces ? .on : .off

        let shortcuts = NSTextField(wrappingLabelWithString: L("""
        ⌥ Tab 按住打开切换器并循环，松开 ⌥ 确认切换
        Tab / Shift+Tab / ← → ↑ ↓ 选择窗口　　数字键 1–9 直选
        / 进入搜索（退格删除，Esc 退出）　　Return / 点击缩略图 立即切换　　Esc 取消
        H 隐藏/显示应用　M 最小化/还原窗口　W 关闭窗口　Q 退出应用　F 全屏切换
        """, """
        Hold ⌥ Tab to open the switcher and cycle; release ⌥ to switch
        Tab / Shift+Tab / ← → ↑ ↓ to select　　Digits 1–9 pick directly
        / to search (Backspace deletes, Esc exits)　　Return / click to switch　　Esc cancels
        H hide/show app　M min/demin window　W close window　Q quit app　F toggle fullscreen
        """))
        shortcuts.font = NSFont.systemFont(ofSize: 11)
        shortcuts.textColor = .secondaryLabelColor

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 14
        grid.columnSpacing = 20
        grid.addRow(with: [label(L("语言", "Language")), langPopup])
        grid.addRow(with: [label(L("卡片大小", "Card size")), sizePopup])
        grid.addRow(with: [label(L("卡片样式", "Card style")), stylePopup])
        let autoSizeCheck = NSButton(checkboxWithTitle: L("按窗口数量自动调整卡片大小", "Adjust card size by window count"),
                                     target: self, action: #selector(autoSizeChanged(_:)))
        autoSizeCheck.state = AppSettings.shared.autoSize ? .on : .off
        grid.addRow(with: [label(L("自动尺寸", "Auto size")), autoSizeCheck])
        grid.addRow(with: [label(L("外观", "Appearance")), themePopup])
        grid.addRow(with: [label(L("皮肤", "Skin")), skinPopup])
        grid.addRow(with: [label(L("大图预览", "Preview")), previewCheck])
        grid.addRow(with: [label(L("显示范围", "Show windows from")), scopePopup])
        grid.addRow(with: [label(L("窗口排序", "Order")), orderPopup])
        grid.addRow(with: [label(L("隐藏应用", "Hidden apps")), hiddenCheck])
        grid.addRow(with: [label(L("无窗口应用", "Windowless apps")), windowlessCheck])
        grid.addRow(with: [label(L("标签页", "Tabs")), tabsCheck])
        grid.addRow(with: [label("Space"), spacesCheck])
        grid.addRow(with: [label(L("面板位置", "Panel screen")), screenPopup])
        grid.addRow(with: [label(L("图标大小", "Icon size")), iconPopup])
        grid.addRow(with: [label(L("标题字号", "Title font")), fontPopup])
        grid.addRow(with: [label(L("最大行数", "Max rows")), rowsPopup])
        grid.addRow(with: [label(L("最小化", "Minimized")), minCheck])
        grid.addRow(with: [label(L("忽略应用", "Ignored apps")), ignoreRow])
        grid.addRow(with: [NSGridCell.emptyContentView, ignoredRow])
        grid.addRow(with: [label(L("松开 ⌥ 时", "On ⌥ release")), releasePopup])
        grid.addRow(with: [label(L("第二快捷键", "2nd shortcut")), ctrlTabCheck])
        grid.addRow(with: [label(L("额外触发键", "Extra triggers")), extraField])
        grid.addRow(with: [label(L("快捷键", "Shortcuts")), shortcuts])
        grid.column(at: 0).xPlacement = .trailing

        let stack = NSStackView(views: [grid])
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        win.contentView = stack
        win.setContentSize(stack.fittingSize)
        win.center()
    }

    private func label(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = NSFont.boldSystemFont(ofSize: 13)
        return f
    }

    func show() {
        activateOurApp()
        win.makeKeyAndOrderFront(nil)
    }

    @objc private func sizeChanged(_ sender: NSPopUpButton) {
        AppSettings.shared.cardSize = CardSize.allCases[sender.indexOfSelectedItem]
    }

    @objc private func cardStyleChanged(_ sender: NSPopUpButton) {
        AppSettings.shared.cardStyle = CardStyle.allCases[sender.indexOfSelectedItem]
    }

    @objc private func autoSizeChanged(_ sender: NSButton) {
        AppSettings.shared.autoSize = sender.state == .on
    }

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        AppSettings.shared.theme = Theme.allCases[sender.indexOfSelectedItem]
    }

    @objc private func skinChanged(_ sender: NSPopUpButton) {
        AppSettings.shared.skin = Skin.allCases[sender.indexOfSelectedItem]
    }

    @objc private func previewChanged(_ sender: NSButton) {
        AppSettings.shared.previewSelectedWindow = sender.state == .on
    }

    @objc private func addIgnoredApp(_ sender: NSButton) {
        guard let popup = ignorePopup, popup.indexOfSelectedItem > 0,
              let name = popup.titleOfSelectedItem else { NSSound.beep(); return }
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == name && $0.activationPolicy == .regular
        }), let bid = app.bundleIdentifier {
            var list = AppSettings.shared.ignoredApps
            if !list.contains(bid) { list.append(bid) }
            AppSettings.shared.ignoredApps = list
            refreshIgnoredList()
        }
    }

    @objc private func clearIgnoredApps(_ sender: NSButton) {
        AppSettings.shared.ignoredApps = []
        refreshIgnoredList()
    }

    private func refreshIgnoredList() {
        ignoredListLabel?.stringValue = L("当前忽略：", "Currently ignored: ")
            + AppSettings.shared.ignoredApps.joined(separator: "、")
        ignoredListLabel?.textColor = .secondaryLabelColor
    }

    @objc private func scopeChanged(_ sender: NSPopUpButton) {
        AppSettings.shared.scope = Scope.allCases[sender.indexOfSelectedItem]
    }

    @objc private func panelScreenChanged(_ sender: NSPopUpButton) {
        AppSettings.shared.panelScreen = PanelScreen.allCases[sender.indexOfSelectedItem]
    }

    @objc private func iconSizeChanged(_ sender: NSPopUpButton) {
        AppSettings.shared.iconSize = IconSize.allCases[sender.indexOfSelectedItem]
    }

    @objc private func titleFontChanged(_ sender: NSPopUpButton) {
        AppSettings.shared.titleFontSize = TitleFontSize.allCases[sender.indexOfSelectedItem]
    }

    /// 下标 0 = 自动，1…5 直接作为行数
    @objc private func maxRowsChanged(_ sender: NSPopUpButton) {
        AppSettings.shared.maxRows = sender.indexOfSelectedItem
    }

    @objc private func minChanged(_ sender: NSButton) {
        AppSettings.shared.showMinimized = sender.state == .on
    }

    @objc private func releaseActionChanged(_ sender: NSPopUpButton) {
        AppSettings.shared.releaseAction = ReleaseAction.allCases[sender.indexOfSelectedItem]
    }

    @objc private func ctrlTabChanged(_ sender: NSButton) {
        AppSettings.shared.enableCtrlTab = sender.state == .on
    }

    @objc private func extraShortcutsChanged(_ sender: NSTextField) {
        AppSettings.shared.extraShortcutsRaw = sender.stringValue
    }

    @objc private func windowOrderChanged(_ sender: NSPopUpButton) {
        AppSettings.shared.windowOrder = WindowOrder.allCases[sender.indexOfSelectedItem]
    }

    @objc private func hiddenAppsChanged(_ sender: NSButton) {
        AppSettings.shared.showHiddenApps = sender.state == .on
    }

    @objc private func windowlessChanged(_ sender: NSButton) {
        AppSettings.shared.showWindowlessApps = sender.state == .on
    }

    @objc private func tabsChanged(_ sender: NSButton) {
        AppSettings.shared.showTabsAsWindows = sender.state == .on
    }

    @objc private func spacesChanged(_ sender: NSButton) {
        AppSettings.shared.showAllSpaces = sender.state != .on
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        AppSettings.shared.language = AppLanguage.allCases[sender.indexOfSelectedItem]
    }
}

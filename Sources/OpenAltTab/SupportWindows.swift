import AppKit

/// 权限引导窗口：检测"辅助功能"和"屏幕录制"，授权后自动关闭
final class PermissionsWindow {
    let win: NSWindow
    private let axStatus = NSTextField(labelWithString: "")
    private let scrStatus = NSTextField(labelWithString: "")

    init() {
        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 280),
                       styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "OpenAltTab 需要权限"

        let title = NSTextField(labelWithString: "首次使用需要授予两项系统权限")
        title.font = NSFont.boldSystemFont(ofSize: 15)

        axStatus.font = NSFont.systemFont(ofSize: 12)
        scrStatus.font = NSFont.systemFont(ofSize: 12)

        let axBtn = NSButton(title: "打开系统设置", target: self, action: #selector(openAX))
        axBtn.bezelStyle = .rounded
        let scrBtn = NSButton(title: "打开系统设置", target: self, action: #selector(openScr))
        scrBtn.bezelStyle = .rounded

        // App 重新编译/移动后签名变化，旧授权条目失效；点此按需重新登记缺失项，无需重启
        let reRegisterBtn = NSButton(title: "重新注册缺失的权限（重新编译 / 移动 App 后点这里）",
                                     target: self, action: #selector(reRegister))
        reRegisterBtn.bezelStyle = .rounded
        reRegisterBtn.keyEquivalent = "\r"
        reRegisterBtn.controlSize = .large

        // 屏幕录制授权与辅助功能不同：开关打开后必须重启进程才能拿到权限
        let restartBtn = NSButton(title: "重启 OpenAltTab（屏幕录制授权需重启才生效）",
                                  target: self, action: #selector(restartApp))
        restartBtn.bezelStyle = .rounded

        let note = NSTextField(wrappingLabelWithString: "用法：点\"重新注册\"（只处理缺失项）→ 系统弹窗确认 → 在列表里打开开关。\n辅助功能即时生效；屏幕录制必须重启 App（点\"重启 OpenAltTab\"按钮）才生效。\n若弹窗仍不出现，点\"在访达中显示\"把 App 拖进列表。")
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 14
        grid.columnSpacing = 16
        grid.addRow(with: [makeRow("辅助功能", axStatus), axBtn])
        grid.addRow(with: [makeRow("屏幕录制", scrStatus), scrBtn])
        grid.column(at: 0).xPlacement = .leading

        let revealBtn = NSButton(title: "在访达中显示 App（弹窗不出现时可手动拖进列表）",
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
            ? "✅ 已授权 — 用于监听 ⌥Tab 按键"
            : "❌ 未授权 — 用于监听 ⌥Tab 按键"
        scrStatus.stringValue = Permissions.screenRecordingGranted
            ? "✅ 已授权 — 用于生成窗口缩略图"
            : "❌ 未授权 — 用于生成窗口缩略图"
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

    init() {
        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                       styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "OpenAltTab 偏好设置"

        let settings = AppSettings.shared

        let sizePopup = NSPopUpButton()
        ["小", "中", "大"].forEach { sizePopup.addItem(withTitle: $0) }
        sizePopup.selectItem(at: settings.cardSize.index)
        sizePopup.target = self
        sizePopup.action = #selector(sizeChanged(_:))

        let themePopup = NSPopUpButton()
        ["跟随系统", "浅色", "深色"].forEach { themePopup.addItem(withTitle: $0) }
        themePopup.selectItem(at: settings.theme.index)
        themePopup.target = self
        themePopup.action = #selector(themeChanged(_:))

        let scopePopup = NSPopUpButton()
        ["所有应用", "仅前台应用"].forEach { scopePopup.addItem(withTitle: $0) }
        scopePopup.selectItem(at: settings.scope.index)
        scopePopup.target = self
        scopePopup.action = #selector(scopeChanged(_:))

        let screenPopup = NSPopUpButton()
        ["目标窗口所在屏幕", "鼠标所在屏幕"].forEach { screenPopup.addItem(withTitle: $0) }
        screenPopup.selectItem(at: settings.panelScreen.index)
        screenPopup.target = self
        screenPopup.action = #selector(panelScreenChanged(_:))

        let iconPopup = NSPopUpButton()
        ["小", "中", "大"].forEach { iconPopup.addItem(withTitle: $0) }
        iconPopup.selectItem(at: settings.iconSize.index)
        iconPopup.target = self
        iconPopup.action = #selector(iconSizeChanged(_:))

        let fontPopup = NSPopUpButton()
        ["小", "中", "大"].forEach { fontPopup.addItem(withTitle: $0) }
        fontPopup.selectItem(at: settings.titleFontSize.index)
        fontPopup.target = self
        fontPopup.action = #selector(titleFontChanged(_:))

        let rowsPopup = NSPopUpButton()
        ["自动", "1 行", "2 行", "3 行", "4 行", "5 行"].forEach { rowsPopup.addItem(withTitle: $0) }
        rowsPopup.selectItem(at: min(settings.maxRows, rowsPopup.itemArray.count - 1))
        rowsPopup.target = self
        rowsPopup.action = #selector(maxRowsChanged(_:))

        let minCheck = NSButton(checkboxWithTitle: "显示已最小化的窗口", target: self, action: #selector(minChanged(_:)))
        minCheck.state = settings.showMinimized ? .on : .off

        let releasePopup = NSPopUpButton()
        ["立即切换", "保持面板（回车确认）", "进入搜索"].forEach { releasePopup.addItem(withTitle: $0) }
        releasePopup.selectItem(at: settings.releaseAction.index)
        releasePopup.target = self
        releasePopup.action = #selector(releaseActionChanged(_:))

        let ctrlTabCheck = NSButton(checkboxWithTitle: "启用 ^Tab 第二组快捷键（Shift+^Tab 反向循环）",
                                    target: self, action: #selector(ctrlTabChanged(_:)))
        ctrlTabCheck.state = settings.enableCtrlTab ? .on : .off

        let orderPopup = NSPopUpButton()
        ["最近聚焦优先", "按名称排序"].forEach { orderPopup.addItem(withTitle: $0) }
        orderPopup.selectItem(at: settings.windowOrder.index)
        orderPopup.target = self
        orderPopup.action = #selector(windowOrderChanged(_:))

        let hiddenCheck = NSButton(checkboxWithTitle: "显示已隐藏应用（⌘H）的窗口",
                                   target: self, action: #selector(hiddenAppsChanged(_:)))
        hiddenCheck.state = settings.showHiddenApps ? .on : .off

        let shortcuts = NSTextField(wrappingLabelWithString: """
        ⌥ Tab 按住打开切换器并循环，松开 ⌥ 确认切换
        Tab / Shift+Tab / ← → ↑ ↓ 选择窗口　　数字键 1–9 直选
        / 进入搜索（退格删除，Esc 退出）　　Return / 点击缩略图 立即切换　　Esc 取消
        H 隐藏/显示应用　M 最小化/还原窗口　W 关闭窗口　Q 退出应用　F 全屏切换
        """)
        shortcuts.font = NSFont.systemFont(ofSize: 11)
        shortcuts.textColor = .secondaryLabelColor

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 14
        grid.columnSpacing = 20
        grid.addRow(with: [label("卡片大小"), sizePopup])
        grid.addRow(with: [label("外观"), themePopup])
        grid.addRow(with: [label("显示范围"), scopePopup])
        grid.addRow(with: [label("窗口排序"), orderPopup])
        grid.addRow(with: [label("隐藏应用"), hiddenCheck])
        grid.addRow(with: [label("面板位置"), screenPopup])
        grid.addRow(with: [label("图标大小"), iconPopup])
        grid.addRow(with: [label("标题字号"), fontPopup])
        grid.addRow(with: [label("最大行数"), rowsPopup])
        grid.addRow(with: [label("最小化"), minCheck])
        grid.addRow(with: [label("松开 ⌥ 时"), releasePopup])
        grid.addRow(with: [label("第二快捷键"), ctrlTabCheck])
        grid.addRow(with: [label("快捷键"), shortcuts])
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

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        AppSettings.shared.theme = Theme.allCases[sender.indexOfSelectedItem]
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

    @objc private func windowOrderChanged(_ sender: NSPopUpButton) {
        AppSettings.shared.windowOrder = WindowOrder.allCases[sender.indexOfSelectedItem]
    }

    @objc private func hiddenAppsChanged(_ sender: NSButton) {
        AppSettings.shared.showHiddenApps = sender.state == .on
    }
}

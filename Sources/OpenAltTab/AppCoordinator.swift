import AppKit
import ApplicationServices

/// 状态机：全局事件捕获 → 打开/循环/提交面板 → 窗口操作
///
/// 安全设计（防止吞掉系统按键）：
/// 1. 事件回调里绝不做慢操作——AX 枚举/聚焦/窗口操作全部走后台队列
/// 2. 面板打开时若 ⌥ 已松开，非导航键一律放行并自动关闭面板（防卡死吞键盘）
/// 3. 字母/数字等按键只在 ⌥ 按住时才被拦截，避免误触 H/M/W/Q 等窗口操作
final class AppCoordinator {
    private let panel = SwitcherPanel()
    private let workQueue = DispatchQueue(label: "OpenAltTab.work", qos: .userInitiated)
    private var items: [WindowItem] = []
    private var selection = 0
    private var visible = false
    /// ⌥Tab 触发后、面板出现前的过渡态（枚举在后台进行）
    private var opening = false
    /// 过渡期间 Tab 自动重复累积的循环数
    private var pendingCycles = 0
    /// 最近一次看到的 ⌥ 按键状态
    private var lastOptionHeld = false
    private var tapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var tapInstalled = false

    init() {
        panel.grid.onPick = { [weak self] i in
            guard let self, self.visible else { return }
            self.selection = i
            self.panel.grid.setSelection(i)
            self.commit()
        }
    }

    // MARK: - 事件捕获

    func start() {
        guard !tapInstalled, Permissions.accessibilityGranted else { return }
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let coordinator = Unmanaged<AppCoordinator>.fromOpaque(userInfo).takeUnretainedValue()
            return coordinator.handle(type: type, event: event)
        }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                           place: .headInsertEventTap,
                                           options: .defaultTap,
                                           eventsOfInterest: mask,
                                           callback: callback,
                                           userInfo: opaque) else { return }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tapPort = port
        runLoopSource = src
        tapInstalled = true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // 系统强制禁用了 tap：先恢复监听，并放弃面板的可疑状态
            if let port = tapPort { CGEvent.tapEnable(tap: port, enable: true) }
            if visible { cancel() }
            return Unmanaged.passUnretained(event)
        default:
            break
        }

        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let hasOption = flags.contains(.maskAlternate)
        let hasCommand = flags.contains(.maskCommand)
        let hasControl = flags.contains(.maskControl)
        let hasShift = flags.contains(.maskShift)
        if type == .keyDown || type == .flagsChanged {
            lastOptionHeld = hasOption
        }

        switch type {
        case .flagsChanged:
            // 松开 Option 键 = 确认切换
            if visible && !hasOption { commit() }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            if visible {
                return handleVisibleKeyDown(code: code, event: event,
                                            hasOption: hasOption, hasCommand: hasCommand,
                                            hasShift: hasShift)
            }
            if code == Key.tab && hasOption && !hasCommand && !hasControl {
                triggerOverlay(reverse: hasShift)
                return nil // 吞掉触发键，避免系统"叮"声
            }

        case .keyUp:
            if code == Key.tab && (visible || opening) { return nil }

        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleVisibleKeyDown(code: Int64, event: CGEvent,
                                      hasOption: Bool, hasCommand: Bool,
                                      hasShift: Bool) -> Unmanaged<CGEvent>? {
        // ⌘Tab：关掉我们的面板，放行系统原生切换器
        if hasCommand && !hasOption && code == Key.tab {
            cancel()
            return Unmanaged.passUnretained(event)
        }

        if hasOption {
            // ⌥ 按住：完整键位可用
            switch code {
            case Key.tab: cycle(hasShift ? -1 : 1)
            case Key.right: cycle(1)
            case Key.left: cycle(-1)
            case Key.down: cycle(panel.grid.perRow)
            case Key.up: cycle(-panel.grid.perRow)
            case Key.return, Key.keypadEnter, Key.space: commit()
            case Key.h: hideApp()
            case Key.m: minimizeWindow()
            case Key.w: closeWindow()
            case Key.q: quitApp()
            default:
                if let digitIndex = Key.digits.firstIndex(of: code) {
                    select(digitIndex)
                }
            }
            return nil
        }

        // ⌥ 已松开：只有导航/取消仍被处理；其余按键放行并关闭面板，
        // 保证任何异常状态下都不会吞掉用户正在输入的内容
        switch code {
        case Key.tab: cycle(hasShift ? -1 : 1)
        case Key.right: cycle(1)
        case Key.left: cycle(-1)
        case Key.down: cycle(panel.grid.perRow)
        case Key.up: cycle(-panel.grid.perRow)
        case Key.escape:
            cancel()
        default:
            cancel()
            return Unmanaged.passUnretained(event)
        }
        return nil
    }

    // MARK: - 面板生命周期

    /// ⌥Tab 触发。枚举在后台执行，事件回调立即返回，绝不阻塞系统按键
    private func triggerOverlay(reverse: Bool) {
        if visible {
            cycle(reverse ? -1 : 1)
            return
        }
        if opening {
            pendingCycles += reverse ? -1 : 1
            return
        }
        opening = true
        workQueue.async { [weak self] in
            guard let self else { return }
            let items = WindowEnumerator.fetch(settings: AppSettings.shared)
            DispatchQueue.main.async {
                self.finishOpening(items: items)
            }
        }
    }

    private func finishOpening(items: [WindowItem]) {
        opening = false
        let cycles = pendingCycles
        pendingCycles = 0
        guard !items.isEmpty else {
            NSSound.beep()
            return
        }
        self.items = items

        // 初始选中：前台应用窗口的下一个
        if let front = NSWorkspace.shared.frontmostApplication,
           let idx = items.firstIndex(where: { $0.app.processIdentifier == front.processIdentifier }) {
            selection = (idx + 1 + cycles) % items.count
        } else {
            selection = ((0 + cycles) % items.count + items.count) % items.count
        }

        // 趁旧前台窗口还在前台：立即补拍一张（此时必然摆正且已渲染），
        // 之后它被台前调度收起时就有干净的缓存可显示
        captureFrontWindowNow(items: items)

        // ⌥ 已经松开（快速轻点 ⌥Tab）：不弹面板，直接切换
        if !lastOptionHeld {
            commitNow(items[selection])
            return
        }

        visible = true
        WindowCapture.invalidateWindowList()
        let screen = targetScreen()
        let size = panel.grid.update(items: items, selection: selection,
                                     thumbSize: AppSettings.shared.cardSize.thumbSize,
                                     maxWidth: screen.visibleFrame.width - 40)
        panel.showCentered(on: screen, size: size)
        scheduleThumbnails()
    }

    /// 立即补拍当前前台应用的主窗口
    private func captureFrontWindowNow(items: [WindowItem]) {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let idx = items.firstIndex(where: { $0.app.processIdentifier == front.processIdentifier }),
              let cgID = items[idx].cgWindowID else { return }
        let cardSize = AppSettings.shared.cardSize.thumbSize
        WindowCapture.refresh(cgID: cgID, cardSize: cardSize,
                              diskKey: items[idx].diskKey, cgFrame: items[idx].cgFrame,
                              axSize: items[idx].screenFrame?.size, delay: 0.05)
    }

    private func targetScreen() -> NSScreen {
        if selection < items.count, let f = items[selection].screenFrame {
            if let s = NSScreen.screens.first(where: { NSPointInRect(f.origin, $0.frame) }) { return s }
        }
        let mouse = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { NSPointInRect(mouse, $0.frame) }) { return s }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    private func scheduleThumbnails() {
        let gen = panel.grid.generation
        let cardSize = AppSettings.shared.cardSize.thumbSize
        for (i, item) in items.enumerated() {
            guard let cgID = item.cgWindowID else { continue }
            if let hit = WindowCapture.cached(cgID: cgID) {
                item.thumbnail = hit
                continue
            }
            WindowCapture.fetch(cgID: cgID, cardSize: cardSize,
                                diskKey: item.diskKey, cgFrame: item.cgFrame,
                                axSize: item.screenFrame?.size) { [weak self] image in
                guard let self, self.visible, self.panel.grid.generation == gen,
                      i < self.items.count else { return }
                self.items[i].thumbnail = image
                self.panel.grid.needsDisplay = true
            }
        }
        panel.grid.needsDisplay = true
    }

    private func cycle(_ delta: Int) {
        guard !items.isEmpty else { return }
        let n = items.count
        selection = (((selection + delta) % n) + n) % n
        panel.grid.setSelection(selection)
    }

    private func select(_ index: Int) {
        guard index < items.count else { return }
        selection = index
        panel.grid.setSelection(index)
    }

    private func commit() {
        guard visible, selection < items.count else { return }
        commitNow(items[selection])
    }

    private func cancel() {
        guard visible else { return }
        dismiss()
    }

    private func dismiss() {
        guard visible else { return }
        visible = false
        pendingCycles = 0
        panel.grid.generation += 1 // 丢弃仍在路上的截图回调
        panel.dismissPanel()
    }

    // MARK: - 窗口操作（全部异步，事件回调不被阻塞）

    /// 切换到目标窗口：AX 部分后台执行（可能遇到无响应应用），
    /// NSRunningApplication API 需要主线程
    private func commitNow(_ item: WindowItem) {
        dismiss()
        workQueue.async {
            if item.isMinimized {
                AXUIElementSetAttributeValue(item.axWindow, kAXMinimizedAttribute as CFString,
                                             kCFBooleanFalse as CFTypeRef)
            }
            AXUIElementSetAttributeValue(item.axApp, kAXFrontmostAttribute as CFString,
                                         kCFBooleanTrue as CFTypeRef)
            AXUIElementPerformAction(item.axWindow, kAXRaiseAction as CFString)
            DispatchQueue.main.async {
                if #available(macOS 14.0, *) {
                    _ = item.app.activate()
                } else {
                    item.app.activate(options: [.activateIgnoringOtherApps])
                }
                // 窗口渲染稳定后重拍高清图，更新"最后所见"缓存：
                // 0.8s / 2.2s 两轮，避开切换动画，确保拿到摆正的画面
                if let cgID = item.cgWindowID {
                    let cardSize = AppSettings.shared.cardSize.thumbSize
                    for delay in [0.8, 2.2] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            WindowCapture.refresh(cgID: cgID, cardSize: cardSize,
                                                  diskKey: item.diskKey, cgFrame: item.cgFrame,
                                                  axSize: item.screenFrame?.size, delay: 0)
                        }
                    }
                }
            }
        }
    }

    private func selectedItem() -> WindowItem? {
        guard visible, selection < items.count else { return nil }
        return items[selection]
    }

    private func hideApp() {
        guard let item = selectedItem() else { return }
        dismiss()
        DispatchQueue.main.async { item.app.hide() }
    }

    private func quitApp() {
        guard let item = selectedItem() else { return }
        dismiss()
        DispatchQueue.main.async { item.app.terminate() }
    }

    private func minimizeWindow() {
        guard let item = selectedItem() else { return }
        dismiss()
        workQueue.async {
            AXUIElementSetAttributeValue(item.axWindow, kAXMinimizedAttribute as CFString,
                                         kCFBooleanTrue as CFTypeRef)
        }
    }

    private func closeWindow() {
        guard let item = selectedItem() else { return }
        dismiss()
        workQueue.async {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(item.axWindow, kAXCloseButtonAttribute as CFString, &v) == .success,
                  let cf = v, CFGetTypeID(cf) == AXUIElementGetTypeID() else { return }
            AXUIElementPerformAction(unsafeDowncast(cf, to: AXUIElement.self), kAXPressAction as CFString)
        }
    }
}

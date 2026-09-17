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
    /// 展示中的窗口列表（搜索模式下是 allItems 的过滤子集）
    private var items: [WindowItem] = []
    /// 全量窗口列表
    private var allItems: [WindowItem] = []
    private var selection = 0
    private var visible = false
    /// ⌥Tab 触发后、面板出现前的过渡态（枚举在后台进行）
    private var opening = false
    /// 过渡期间 Tab 自动重复累积的循环数
    private var pendingCycles = 0
    /// 最近一次看到的 ⌥ 按键状态
    private var lastOptionHeld = false
    /// 最近一次看到的 ⌃ 按键状态（^Tab 触发组用）
    private var lastControlHeld = false
    /// 当前面板由哪组快捷键触发：false = ⌥Tab，true = ^Tab（决定松开哪个键时执行松开行为）
    private var triggeredByCtrlTab = false
    /// 搜索模式（/ 进入）：字母数字追加查询，过滤 items
    private var searchMode = false
    private var query = ""
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
            | (1 << CGEventType.scrollWheel.rawValue)
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
            lastControlHeld = hasControl
        }

        switch type {
        case .flagsChanged:
            // 松开触发键 = 执行松开行为（立即切换 / 保持面板 / 进入搜索）
            if visible {
                let released = triggeredByCtrlTab ? !hasControl : !hasOption
                if released {
                    switch AppSettings.shared.releaseAction {
                    case .focus:
                        commit()
                    case .hold:
                        break // 保持面板，等回车/Esc/导航键
                    case .search:
                        if !searchMode { enterSearch() }
                    }
                }
            }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            if visible {
                return handleVisibleKeyDown(code: code, event: event,
                                            hasOption: hasOption, hasCommand: hasCommand,
                                            hasShift: hasShift)
            }
            if code == Key.tab && !hasCommand {
                let useOption = hasOption
                let useControl = !hasOption && hasControl && AppSettings.shared.enableCtrlTab
                if useOption || useControl {
                    triggeredByCtrlTab = useControl
                    triggerOverlay(reverse: hasShift)
                    return nil // 吞掉触发键，避免系统"叮"声
                }
            }

        case .keyUp:
            if code == Key.tab && (visible || opening) { return nil }

        case .scrollWheel:
            // 面板打开时滚轮循环选择（对齐 AltTab）； deltaX 支持横向滚动的左右循环
            if visible {
                let dy = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
                let dx = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
                if dy != 0 {
                    cycle(dy > 0 ? -1 : 1)
                    return nil
                }
                if dx != 0 {
                    cycle(dx > 0 ? -1 : 1)
                    return nil
                }
            }

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
            // ⌥ 按住：搜索模式有独立键位；否则完整键位可用
            if searchMode {
                return handleSearchKeyDown(code: code, event: event, hasShift: hasShift)
            }
            switch code {
            case Key.tab: cycle(hasShift ? -1 : 1)
            case Key.right: cycle(1)
            case Key.left: cycle(-1)
            case Key.down: cycle(panel.grid.perRow)
            case Key.up: cycle(-panel.grid.perRow)
            case Key.return, Key.keypadEnter, Key.space: commit()
            case Key.slash: enterSearch()
            case Key.h: hideShowApp()
            case Key.f: toggleFullscreen()
            case Key.m: minDeminWindow()
            case Key.w: closeWindow()
            case Key.q: quitApp()
            default:
                if let digitIndex = Key.digits.firstIndex(of: code) {
                    select(digitIndex)
                }
            }
            return nil
        }

        // 触发键已松开。松开行为为"保持面板/进入搜索"时（sticky），导航、回车继续可用，
        // 搜索模式下可打印字符进查询；其余按键放行并关闭面板，
        // 保证任何异常状态下都不会吞掉用户正在输入的内容
        let sticky = AppSettings.shared.releaseAction != .focus
        switch code {
        case Key.tab: cycle(hasShift ? -1 : 1)
        case Key.right: cycle(1)
        case Key.left: cycle(-1)
        case Key.down: cycle(panel.grid.perRow)
        case Key.up: cycle(-panel.grid.perRow)
        case Key.return, Key.keypadEnter:
            if sticky { commit() } else { cancel(); return Unmanaged.passUnretained(event) }
        case Key.escape:
            if sticky && searchMode {
                exitSearch()
            } else {
                cancel()
            }
        case Key.backspace:
            if sticky && searchMode {
                if query.isEmpty { exitSearch() } else { query.removeLast(); applyFilter() }
            } else {
                cancel()
                return Unmanaged.passUnretained(event)
            }
        default:
            if sticky && searchMode, let ch = SearchInput.character(from: event) {
                query += ch
                applyFilter()
            } else {
                cancel()
                return Unmanaged.passUnretained(event)
            }
        }
        return nil
    }

    /// 搜索模式键位：可打印字符追加查询；退格删除（空则退出）；
    /// Enter 提交、Esc 退出搜索；Tab/方向键仍循环。字母不再触发 H/M/W/Q 窗口操作
    private func handleSearchKeyDown(code: Int64, event: CGEvent, hasShift: Bool) -> Unmanaged<CGEvent>? {
        switch code {
        case Key.tab: cycle(hasShift ? -1 : 1)
        case Key.right: cycle(1)
        case Key.left: cycle(-1)
        case Key.down: cycle(panel.grid.perRow)
        case Key.up: cycle(-panel.grid.perRow)
        case Key.return, Key.keypadEnter: commit()
        case Key.escape: exitSearch()
        case Key.backspace:
            if query.isEmpty {
                exitSearch()
            } else {
                query.removeLast()
                applyFilter()
            }
        default:
            if let ch = SearchInput.character(from: event) {
                query += ch
                applyFilter()
            }
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
        allItems = items
        self.items = items
        searchMode = false
        query = ""

        // 初始选中：前台应用窗口的下一个
        if let front = NSWorkspace.shared.frontmostApplication,
           let idx = allItems.firstIndex(where: { $0.app.processIdentifier == front.processIdentifier }) {
            selection = (idx + 1 + cycles) % allItems.count
        } else {
            selection = ((0 + cycles) % allItems.count + allItems.count) % allItems.count
        }

        // 趁旧前台窗口还在前台：立即补拍一张（此时必然摆正且已渲染），
        // 之后它被台前调度收起时就有干净的缓存可显示
        captureFrontWindowNow(items: allItems)

        // ⌥ 已经松开（快速轻点 ⌥Tab）：不弹面板，直接切换
        let triggerStillHeld = triggeredByCtrlTab ? lastControlHeld : lastOptionHeld
        if !triggerStillHeld {
            commitNow(allItems[selection])
            return
        }

        visible = true
        WindowCapture.invalidateWindowList()
        relayout()
        scheduleThumbnails()
    }

    /// 按当前 items/搜索状态重建网格并调整面板尺寸（过滤时面板随之缩放）
    private func relayout() {
        let screen = targetScreen()
        let size = panel.grid.update(items: items, selection: selection,
                                     thumbSize: AppSettings.shared.cardSize.thumbSize,
                                     maxWidth: screen.visibleFrame.width - 40,
                                     searchLine: searchLineText())
        panel.showCentered(on: screen, size: size)
    }

    private func searchLineText() -> String? {
        guard searchMode else { return nil }
        return "搜索: \(query)　\(items.count)/\(allItems.count)"
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

    /// 面板出现的屏幕：按偏好优先取"目标窗口所在屏幕"或"鼠标所在屏幕"，另一边作兜底
    private func targetScreen() -> NSScreen {
        let targetOfSelection: NSScreen? = {
            guard selection < items.count, let f = items[selection].screenFrame else { return nil }
            return NSScreen.screens.first { NSPointInRect(f.origin, $0.frame) }
        }()
        let mouseOn: NSScreen? = NSScreen.screens.first { NSPointInRect(NSEvent.mouseLocation, $0.frame) }
        let preferred = AppSettings.shared.panelScreen == .mouse ? mouseOn : targetOfSelection
        return preferred ?? mouseOn ?? targetOfSelection ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func scheduleThumbnails() {
        let gen = panel.grid.generation
        let cardSize = AppSettings.shared.cardSize.thumbSize
        for item in items {
            guard let cgID = item.cgWindowID else { continue }
            if let hit = WindowCapture.cached(cgID: cgID) {
                item.thumbnail = hit
                continue
            }
            WindowCapture.fetch(cgID: cgID, cardSize: cardSize,
                                diskKey: item.diskKey, cgFrame: item.cgFrame,
                                axSize: item.screenFrame?.size) { [weak self] image in
                // 完成回调直接赋值到窗口对象上：搜索过滤会改变 items 的下标，
                // 按 i 取会错位，对象引用不会；-generation 检查保证面板已关闭就丢弃
                guard let self, self.visible, self.panel.grid.generation == gen else { return }
                item.thumbnail = image
                self.panel.grid.needsDisplay = true
            }
        }
        panel.grid.needsDisplay = true
    }

    // MARK: - 搜索过滤

    private func enterSearch() {
        searchMode = true
        query = ""
        applyFilter()
    }

    private func exitSearch() {
        searchMode = false
        query = ""
        applyFilter()
    }

    /// 按查询过滤（应用名 + 窗口标题），按相关性降序、同分保持原相对顺序；
    /// 原选中窗口仍在结果里时保持其选中位置
    private func applyFilter() {
        let current = selection < items.count ? items[selection] : nil
        if query.isEmpty {
            items = allItems
        } else {
            var scored: [(item: WindowItem, score: Double, order: Int)] = []
            scored.reserveCapacity(allItems.count)
            for (i, it) in allItems.enumerated() {
                let s = Search.bestSimilarity(query: query, appName: it.appName, title: it.title)
                if s > 0 { scored.append((it, s, i)) }
            }
            scored.sort { a, b in a.score != b.score ? a.score > b.score : a.order < b.order }
            items = scored.map(\.item)
        }
        selection = current.flatMap { c in items.firstIndex { $0 === c } } ?? 0
        relayout()
        scheduleThumbnails()
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
        triggeredByCtrlTab = false
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

    /// 切换语义（对齐 AltTab）：应用隐藏中则恢复显示，否则隐藏
    private func hideShowApp() {
        guard let item = selectedItem() else { return }
        dismiss()
        DispatchQueue.main.async {
            item.app.isHidden ? item.app.unhide() : item.app.hide()
        }
    }

    private func quitApp() {
        guard let item = selectedItem() else { return }
        dismiss()
        DispatchQueue.main.async { item.app.terminate() }
    }

    /// 切换语义：最小化↔还原。全屏窗口先退全屏（动画约 1s），再补最小化
    private func minDeminWindow() {
        guard let item = selectedItem() else { return }
        dismiss()
        workQueue.async {
            if item.isFullscreen {
                AXUIElementSetAttributeValue(item.axWindow, "AXFullScreen" as CFString,
                                             kCFBooleanFalse as CFTypeRef)
                // 全屏退场动画没结束前 AX 会忽略 minimize，等 1 秒再发
                workQueueAfter(1.0) {
                    AXUIElementSetAttributeValue(item.axWindow, kAXMinimizedAttribute as CFString,
                                                 kCFBooleanTrue as CFTypeRef)
                }
            } else {
                let flag: CFTypeRef = item.isMinimized ? kCFBooleanFalse : kCFBooleanTrue
                AXUIElementSetAttributeValue(item.axWindow, kAXMinimizedAttribute as CFString, flag)
            }
        }
    }

    /// 全屏↔还原。AX 属性写入对不响应"AXFullScreen"的应用无效（保持原状态）
    private func toggleFullscreen() {
        guard let item = selectedItem() else { return }
        dismiss()
        workQueue.async {
            AXUIElementSetAttributeValue(item.axWindow, "AXFullScreen" as CFString,
                                         (item.isFullscreen ? kCFBooleanFalse : kCFBooleanTrue) as CFTypeRef)
        }
    }

    private func closeWindow() {
        guard let item = selectedItem() else { return }
        dismiss()
        workQueue.async {
            func pressClose() {
                var v: CFTypeRef?
                guard AXUIElementCopyAttributeValue(item.axWindow, kAXCloseButtonAttribute as CFString, &v) == .success,
                      let cf = v, CFGetTypeID(cf) == AXUIElementGetTypeID() else { return }
                AXUIElementPerformAction(unsafeDowncast(cf, to: AXUIElement.self), kAXPressAction as CFString)
            }
            if item.isFullscreen {
                // 全屏下点关闭按钮可能无效：先退全屏，动画结束后再按
                AXUIElementSetAttributeValue(item.axWindow, "AXFullScreen" as CFString,
                                             kCFBooleanFalse as CFTypeRef)
                workQueueAfter(1.0, pressClose)
            } else {
                pressClose()
            }
        }
    }
}

/// workQueue 自延迟：全局函数是为了在闭包里不用捕获 coordinator
private func workQueueAfter(_ seconds: TimeInterval, _ block: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        DispatchQueue.global(qos: .userInitiated).async(execute: block)
    }
}

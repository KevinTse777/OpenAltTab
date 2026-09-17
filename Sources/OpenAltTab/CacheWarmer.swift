import AppKit

/// 缓存预热：监听全局应用激活事件，应用切到前台约 2 秒后（渲染稳定）自动补拍其前台窗口，
/// 持续填充"最后所见"缩略图缓存。用户正常使用过的每个窗口都会被渐进式捕获，
/// 之后无论被台前调度收起到哪里，切换器里都有摆正的预览可显示。
///
/// 这解决了"切换过的窗口仍然显示图标"的主要缺口：仅靠切换器自己的切换后重拍，
/// 快速连续切换时（<2s/个）来不及稳定渲染就错过了；预热器则以用户真实的窗口使用节奏
/// 在后台持续补全缓存。
final class CacheWarmer {
    private var pending: [pid_t: DispatchWorkItem] = [:]
    private let queue = DispatchQueue(label: "OpenAltTab.warmer")
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self?.schedule(app: app)
        }
    }

    /// 每个应用只排一次队（去抖）：快速连切时中间应用也会在 2 秒后被补拍
    private func schedule(app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pending[pid] == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pending[pid] = nil
            self?.captureFront(of: app)
        }
        pending[pid] = work
        queue.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    private func captureFront(of app: NSRunningApplication) {
        // 排队期间用户可能又切走了：只拍仍在前台的（后台窗口此时多半已被缩放/收起，拍了也是斜的）
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
        guard let info = WindowEnumerator.frontWindowSummary(for: app) else { return }
        WindowCapture.refresh(cgID: info.cgID,
                              cardSize: AppSettings.shared.cardSize.thumbSize,
                              diskKey: info.diskKey, cgFrame: info.cgFrame,
                              axSize: info.axSize, delay: 0.4)
    }
}

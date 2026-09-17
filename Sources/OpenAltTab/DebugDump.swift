import AppKit
import ApplicationServices
import ScreenCaptureKit

/// 线程安全日志槽：收集并发任务里的诊断输出
final class DebugSink: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func log(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

let debugSink = DebugSink()

/// 诊断模式：`OpenAltTab --dump-windows`
/// 枚举所有窗口并尝试两种截图方式，结果写到 /tmp/openalttab_dump.txt，截图存到 /tmp/oat_*.png
enum DebugDump {
    static func run() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        var lines: [String] = []
        func log(_ s: String) { lines.append(s) }

        let stageOn = CFPreferencesCopyAppValue("GloballyEnabled" as CFString,
                                                "com.apple.WindowManager" as CFString) as? Bool ?? false
        log("StageManager=\(stageOn) AXTrusted=\(Permissions.accessibilityGranted) ScreenRecording=\(Permissions.screenRecordingGranted)")

        // CGWindowList 原始数据（层 0）
        log("\n=== CGWindowList layer0 ===")
        let cgList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in cgList {
            guard w[kCGWindowLayer as String] as? Int == 0 else { continue }
            let id = w[kCGWindowNumber as String] as? Int ?? -1
            let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
            let onscreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
            let name = w[kCGWindowName as String] as? String ?? ""
            let b = (w[kCGWindowBounds as String] as? [String: Any])
                .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
            log(String(format: "id=%d on=%d (%.0f,%.0f %.0fx%.0f) %@ '%@'",
                       id, onscreen ? 1 : 0, b.origin.x, b.origin.y, b.width, b.height, owner, name))
        }

        // 截图目标：直接从 CGWindowList 挑（不依赖辅助功能权限），覆盖屏上/屏外窗口
        var targets: [(app: String, cgID: CGWindowID, on: Bool)] = []
        for w in cgList {
            guard w[kCGWindowLayer as String] as? Int == 0,
                  w[kCGWindowOwnerPID as String] as? Int != Int(ProcessInfo.processInfo.processIdentifier) else { continue }
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            let skip = ["CursorUIViewService", "WindowManager", "OpenAltTab",
                        "AutoFill", "自动填充", "nsattributedstringagent"]
            if skip.contains(owner) { continue }
            let id = w[kCGWindowNumber as String] as? Int ?? -1
            let onscreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
            let b = (w[kCGWindowBounds as String] as? [String: Any])
                .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
            if b.width * b.height < 8000 { continue }
            if !targets.contains(where: { $0.cgID == CGWindowID(id) }) {
                targets.append((owner, CGWindowID(id), onscreen))
            }
        }
        // 优先抓台前调度条目的小窗口（贴屏幕左缘、宽 <220pt），用于检查"倾斜"问题
        targets.sort {
            let small1 = $0.on && $0.cgID != 0
            let small2 = $1.on && $1.cgID != 0
            return small1 && !small2
        }
        if targets.count > 8 { targets = Array(targets.prefix(8)) }

        // AX 枚举（有辅助功能权限时才可用）
        log("\n=== AX windows ===")
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        for app in apps {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var list: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &list) == .success,
                  let axWindows = list as? [AXUIElement] else {
                log("\(app.localizedName ?? "?") pid=\(app.processIdentifier): no AX windows")
                continue
            }
            for axw in axWindows {
                let title = axString(axw, kAXTitleAttribute) ?? "<nil>"
                let minimized = axBool(axw, kAXMinimizedAttribute)
                let size = axSizeOf(axw, kAXSizeAttribute)
                let pos = axPointOf(axw, kAXPositionAttribute)
                var cgID: CGWindowID = 0
                let ok = _AXUIElementGetWindow(axw, &cgID) == .success
                log(String(format: "%@ pid=%d '%@' min=%d size=%@ pos=%@ cgid=%@",
                           app.localizedName ?? "?", app.processIdentifier, title,
                           minimized ? 1 : 0,
                           size.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil",
                           pos.map { "\(Int($0.x)),\(Int($0.y))" } ?? "nil",
                           ok ? "\(cgID)" : "nil"))
            }
        }

        // 截图对比：CG 旧 API 同步，SC 异步，全部完成后写文件退出
        log("\n=== captures ===")
        let group = DispatchGroup()
        let lock = NSLock()
        for (i, t) in targets.enumerated() {
            let tag = "\(i)_\(t.app)_id\(t.cgID)_\(t.on ? "on" : "off")"
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: " ", with: "_")
            if let img = WindowCapture.rawImage(cgID: t.cgID) {
                savePNG(img, "/tmp/oat_\(tag)_cg.png")
                log("CG id=\(t.cgID) \(t.app): \(img.width)x\(img.height)")
            } else {
                log("CG id=\(t.cgID) \(t.app): NIL")
            }
            group.enter()
            if #available(macOS 14.0, *) {
            debugSCCapture(cgID: t.cgID) { img in
                lock.lock()
                if let img {
                    savePNG(img, "/tmp/oat_\(tag)_sc.png")
                    log("SC id=\(t.cgID) \(t.app): \(img.width)x\(img.height)")
                } else {
                    log("SC id=\(t.cgID) \(t.app): NIL")
                }
                lock.unlock()
                group.leave()
            }
            }
        }
        _ = group.wait(timeout: .now() + 60)
        lines.append(contentsOf: debugSink.all)

        let text = lines.joined(separator: "\n")
        try? text.write(toFile: "/tmp/openalttab_dump.txt", atomically: true, encoding: .utf8)
        print(text)
        exit(0)
    }

    /// 诊断专用 SC 截图（强制全新窗口列表，错误写入 debugSink）
    @available(macOS 14.0, *)
    static func debugSCCapture(cgID: CGWindowID, completion: @escaping (CGImage?) -> Void) {
        Task.detached(priority: .high) {
            var result: CGImage?
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                debugSink.log("SC content windows=\(content.windows.count)")
                if let window = content.windows.first(where: { $0.windowID == cgID }) {
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    let config = SCStreamConfiguration()
                    let w = max(1, window.frame.width)
                    let h = max(1, window.frame.height)
                    if w >= h {
                        config.width = 960
                        config.height = max(1, 960 * Int(h) / Int(w))
                    } else {
                        config.height = 960
                        config.width = max(1, 960 * Int(w) / Int(h))
                    }
                    config.showsCursor = false
                    config.captureResolution = .best
                    config.ignoreShadowsSingleWindow = true
                    result = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                } else {
                    debugSink.log("SC window id=\(cgID) not in shareable content")
                }
            } catch {
                debugSink.log("SC error: \(error)")
                result = nil
            }
            completion(result)
        }
    }

    private static func savePNG(_ img: CGImage, _ path: String) {
        let rep = NSBitmapImageRep(cgImage: img)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
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

    private static func axPointOf(_ el: AXUIElement, _ attr: String) -> CGPoint? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        guard let cf = v, CFGetTypeID(cf) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        guard AXValueGetValue(unsafeDowncast(cf, to: AXValue.self), .cgPoint, &p) else { return nil }
        return p
    }

    private static func axSizeOf(_ el: AXUIElement, _ attr: String) -> CGSize? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        guard let cf = v, CFGetTypeID(cf) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(cf, to: AXValue.self), .cgSize, &s) else { return nil }
        return s
    }
}

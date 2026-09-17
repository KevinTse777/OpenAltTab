import AppKit
import ApplicationServices
import ScreenCaptureKit

enum Permissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// 弹出系统授权对话框：让系统把本 App 重新登记进"辅助功能"授权列表。
    /// App 重新编译（签名变化）或移动位置导致旧条目失效后，点一下即可重新注册，无需重启
    static func promptAccessibilityRegistration() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// 触发屏幕录制授权流程：系统会把 App 加进"屏幕录制"列表。
    /// 现代 macOS 只有在实际发起截屏时才弹授权提示/登记条目，
    /// 所以除了官方 API，再真实发起一次截屏尝试（无权限时内容也是无效的，无副作用）
    static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        DispatchQueue.global(qos: .userInitiated).async {
            _ = CGWindowListCreateImage(CGRect.null, .optionOnScreenOnly, kCGNullWindowID,
                                        [.bestResolution])
        }
        if #available(macOS 14.0, *) {
            Task {
                _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            }
        }
    }

    /// 程序化清除本 App 的屏幕录制注册状态（等同重置"已询问过"标记）。
    /// 手动在系统设置里删掉条目并不会清掉这个标记，导致 CGRequestScreenCaptureAccess
    /// 被静默忽略、列表里始终不出现新条目——先 reset 再 request 才能重新弹窗
    static func resetScreenRecordingRegistration() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "ScreenCapture",
                       Bundle.main.bundleIdentifier ?? "com.openalttab.macos"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    static func openAccessibilitySettings() {
        openPane("com.apple.preference.security?Privacy_Accessibility")
    }

    static func openScreenRecordingSettings() {
        openPane("com.apple.preference.security?Privacy_ScreenCapture")
    }

    private static func openPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

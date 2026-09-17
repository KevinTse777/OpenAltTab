import AppKit
import Darwin

/// SkyLight 私有 API 隔离封装：`CGSHWCaptureWindowList` 能拍到最小化窗口的内容
/// （CGWindowListCreateImage 拍不到），其 fullSize 位还能规避台前调度的倾斜合成
/// （选项值取自上游 alt-tab-macos 的 SkyLight.framework.swift）。
///
/// 通过 dlopen + dlsym 惰性绑定而非直接链接：SwiftPM 构建不链接 SkyLight 框架，
/// 直接引用私有符号会导致启动时 dyld 解析失败崩溃。任一符号缺失时本模块整体不可用，
/// 截图管线自动走原有回退路径。
enum HWCapture {
    private static let options: UInt32 = (1 << 8)   // bestResolution
        | (1 << 11)   // ignoreGlobalClipShape
        | (1 << 19)   // fullSize：台前调度下也拿不倾斜的整窗画面

    private typealias MainConnectionFn = (@convention(c) () -> UInt32)
    private typealias HWCaptureFn = (@convention(c) (UInt32, UnsafeMutablePointer<UInt32>?, UInt32, UInt32) -> CFArray?)

    private static let mainConnection: MainConnectionFn? = bind("CGSMainConnectionID")
    private static let hwCapture: HWCaptureFn? = bind("CGSHWCaptureWindowList")

    static var available: Bool { mainConnection != nil && hwCapture != nil }

    private static func bind<T>(_ symbol: String) -> T? {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let ptr = dlsym(handle, symbol) else { return nil }
        return unsafeBitCast(ptr, to: T.self)
    }

    /// 拍指定窗口；不可用或失败返回 nil
    static func capture(cgID: CGWindowID) -> CGImage? {
        guard available, let con = mainConnection, let hw = hwCapture, con() != 0 else { return nil }
        var wid = cgID
        guard let array = hw(con(), &wid, 1, options) as? [CGImage] else { return nil }
        return array.first
    }
}

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

/// SkyLight Space 查询（同样的 dlopen 隔离）：
/// 用于"仅显示当前桌面"过滤——每个窗口查它所属的 Space，再和当前活跃 Space 比对。
/// 任一符号缺失时 available == false，过滤自动退化为"显示全部 Space"。
enum SpaceQuery {
    /// CGSSpaceMask.all（取值来自上游 alt-tab-macos 的 SkyLight 封装）
    private static let maskAll = 7

    private typealias MainConnectionFn = (@convention(c) () -> UInt32)
    private typealias CopySpacesForWindowsFn = (@convention(c) (UInt32, Int, CFArray) -> CFArray?)
    private typealias CopyActiveSpaceFn = (@convention(c) (UInt32) -> UInt64)

    private static let mainConnection: MainConnectionFn? = bind("CGSMainConnectionID")
    private static let copySpaces: CopySpacesForWindowsFn? = bind("CGSCopySpacesForWindows")
    private static let copyActive: CopyActiveSpaceFn? = bind("CGSCopyActiveSpace")

    static var available: Bool { mainConnection != nil && copySpaces != nil && copyActive != nil }

    private static func bind<T>(_ symbol: String) -> T? {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let ptr = dlsym(handle, symbol) else { return nil }
        return unsafeBitCast(ptr, to: T.self)
    }

    /// 当前活跃 Space；查询失败返回 nil
    static func activeSpace() -> UInt64? {
        guard available, let con = mainConnection, con() != 0, let copy = copyActive else { return nil }
        let id = copy(con())
        return id == 0 ? nil : id
    }

    /// 某窗口所属的 Space 集合；查询失败返回 nil
    static func spacesOfWindow(_ wid: CGWindowID) -> Set<UInt64>? {
        guard available, let con = mainConnection, con() != 0, let copy = copySpaces else { return nil }
        guard let result = copy(con(), maskAll, [NSNumber(value: wid)] as CFArray) as? [NSNumber] else {
            return nil
        }
        return Set(result.map(\.uint64Value))
    }
}

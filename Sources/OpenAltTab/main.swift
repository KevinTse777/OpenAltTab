import AppKit

// 诊断模式：枚举窗口 + 截图对比，写入 /tmp/openalttab_dump.txt 后退出
if CommandLine.arguments.contains("--dump-windows") {
    DebugDump.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

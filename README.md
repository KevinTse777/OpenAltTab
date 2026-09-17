# OpenAltTab

macOS 上的 Windows 风格窗口切换器：按住 **⌥ (Option) + Tab**，弹出所有窗口的实时缩略图，松开 ⌥ 即刻切换。

参考 [AltTab](https://alt-tab.xyz)（GitHub: lwouis/alt-tab-macos）的功能形态自行实现——**全部功能免费、无任何付费墙**。GitHub 上的 AltTab 本身是免费开源项目（页面上的按钮是捐赠，不是付费解锁）；真正收费的是 Witch、Contexts 这类同类工具，本项目把它们的常用付费功能也一并实现了。

![概念示意](https://img.shields.io/badge/macOS-13%2B-blue) ![构建](https://img.shields.io/badge/Swift%20Package-swift%20build-orange)

## 功能

- ⌥Tab 按住呼出、松开即切换（Windows 手感）
- 每个窗口一个缩略图（不是每个应用一个），支持已最小化窗口
- 键盘：`Tab` / `Shift+Tab` / `←→↑↓` 循环选择，`1–9` 数字直选，`Return` 确认，`Esc` 取消
- 鼠标：点击缩略图直接切换
- 窗口操作快捷键（选中后按下即生效）：
  - `H` 隐藏该应用　`M` 最小化该窗口　`W` 关闭该窗口　`Q` 退出该应用
- `⌘Tab` 完全不受影响，仍调用系统原生切换器（呼出面板后按 ⌘Tab 会让位给原生）
- 多显示器：面板出现在目标窗口所在的屏幕
- 外观：毛玻璃面板，深色/浅色/跟随系统，卡片大小三档可选
- 可选只显示前台应用的窗口；登录自启动（SMAppService）
- 菜单栏常驻图标：权限状态、偏好设置、清除缩略图缓存、登录自启、退出
- **缓存预热器**：监听全局应用激活事件，每个应用切到前台约 2 秒后自动补拍其前台窗口——
  用户正常使用过的窗口都会被渐进式捕获进"最后所见"缓存，快速连切也不漏

## 构建与安装

需要 Xcode 或 Command Line Tools（`xcode-select --install`）。

```bash
cd OpenAltTab
./scripts/make_app.sh        # swift build -c release + 组装 .app + ad-hoc 签名
open OpenAltTab.app
```

建议先 `cp -R OpenAltTab.app /Applications/` 再启动再授权（授权信息与 App 路径/签名绑定，移动后可能需要重新授权一次）。

## 首次使用：授予两项权限

启动后 App 会弹出权限引导窗口，并每秒自动检测，授权完成后自动关闭、无需重启：

| 权限 | 用途 | 位置 |
|---|---|---|
| 辅助功能 | 全局监听 ⌥Tab 按键、枚举/切换/最小化窗口 | 系统设置 → 隐私与安全性 → 辅助功能 |
| 屏幕录制 | 生成窗口实时缩略图 | 系统设置 → 隐私与安全性 → 屏幕录制 |

不授权屏幕录制时功能仍可用，但缩略图会显示为应用图标占位图。

> 重新编译后授权失效？ad-hoc 签名的 App 在重新构建后 cdhash 会变化，macOS 可能要求重新授权：在隐私列表里先移除旧条目再重新添加即可。

## 使用方法

1. 按住 `⌥ Option`，按一下 `Tab`：切换器出现并选中下一个窗口
2. 继续按住 `⌥` 的同时：`Tab` 向前循环、`Shift+Tab` 向后、方向键自由移动、数字键直选
3. 松开 `⌥`：立即切换到选中的窗口
4. 也可以直接按 `H` / `M` / `W` / `Q` 对选中项执行隐藏 / 最小化 / 关闭 / 退出

菜单栏图标 → 偏好设置：卡片大小、深浅色主题、显示范围（所有应用 / 仅前台应用）、是否显示最小化窗口。

## 项目结构

```
OpenAltTab/
├── Package.swift                     # SwiftPM，无第三方依赖
├── Sources/OpenAltTab/
│   ├── main.swift                    # 入口：无 Dock 图标的常驻 App
│   ├── AppDelegate.swift             # 菜单栏、权限轮询、设置入口
│   ├── AppCoordinator.swift          # 事件状态机：呼出/循环/提交/窗口操作
│   ├── SwitcherPanel.swift           # NSPanel（不激活、全屏 Space 可见）+ 手绘缩略图网格
│   ├── WindowEnumerator.swift        # AX API 枚举窗口：标题/最小化/位置/CGWindowID 映射
│   ├── WindowCapture.swift           # 后台线程截图 + 降采样缓存
│   ├── AppSettings.swift             # UserDefaults 偏好
│   ├── SupportWindows.swift          # 权限引导窗口、偏好设置窗口
│   ├── Permissions.swift             # 辅助功能/屏幕录制权限检测与跳转
│   └── Keys.swift                    # 虚拟键码表
└── scripts/make_app.sh               # 编译 + 组装 .app + ad-hoc 签名
```

### 实现要点（对照 AltTab 的做法）

- **缩略图缓存体系**：内存 LRU（256 条）+ 磁盘持久化（`~/Library/Caches/com.openalttab.macos/thumbs`，按"应用+窗口标题"键存长边 640px 高清版，上限 150 张）双层；写入时机：面板打开瞬间的前台窗口、切换成功后 0.8s/2.2s 两轮重拍、CacheWarmer 激活预热。菜单栏可一键清空

- **按键捕获（防吞字设计）**：`CGEventTap`（session 级、defaultTap）只拦 `Tab` 的按下/抬起和修饰键变化；**事件回调里绝不做慢操作**——AX 枚举、聚焦、窗口操作全部在后台队列执行，回调立即返回；面板打开时若 ⌥ 已松开，非导航键一律放行并自动关闭面板，任何异常状态都不会吞掉正在输入的内容；H/M/W/Q 等窗口操作键必须按住 ⌥ 才生效，避免误关窗口；`⌘Tab` 原样放行；tap 被系统强制禁用时自动恢复并放弃面板状态
- **窗口枚举**：每个正在运行的常规应用通过 `AXUIElement`（辅助功能 API）取窗口列表，比纯 `CGWindowList` 多拿到最小化/其他 Space 的窗口；用私有但多年稳定的 `_AXUIElementGetWindow` 把 AX 窗口映射为 `CGWindowID`（AltTab 同款做法），并设置 0.35s 消息超时防止单个无响应应用卡住全局
- **应用排序**：监听 `NSWorkspace.didActivateApplicationNotification` 维护最近使用顺序，前台应用永远排第一
- **缩略图（台前调度友好）**：
  - 主路径 ScreenCaptureKit `SCScreenshotManager` + `SCContentFilter(desktopIndependentWindow:)`，独立于窗口是否在屏幕上截图；失败自动重试一次（SC 偶发 -3811 瞬时错误）；最后以旧 `CGWindowListCreateImage` 兜底
  - **倾斜条目拒绝**：macOS 26 台前调度把左侧条目窗口以"缩小 + 3D 倾斜"合成，任何截图 API 拿到的都是倾斜画面。通过 SC 逻辑尺寸 ÷ CG 实际边界 > 1.5 识别这类窗口并拒绝实拍
  - **"最后所见"持久缓存**：预览图按"应用+窗口标题"存磁盘（`~/Library/Caches/com.openalttab.macos/thumbs`，上限 150 张 LRU）；窗口每次成为前台 1.2 秒后自动重拍更新。被收起的窗口优先显示缓存里那张摆正的预览
  - **纯色占位图检测**：驻留屏幕外太久、渲染缓存被系统清除的窗口只能截到单色画面（灰/黑/白），视为无效内容，显示应用图标占位
- **切换**：取消最小化（AX）→ 激活应用 → AX Raise 目标窗口

## 已知限制

- macOS 出于安全设计，**其他 Space（全屏桌面）里的窗口不参与枚举**——这是 API 级限制，AltTab 也一样；切换到对应 Space 后即可看到
- 浏览器的多个标签页在系统层面是同一个窗口，切换器里也显示为一个窗口
- `CGWindowListCreateImage` 自 macOS 14 起被 Apple 标记弃用（目前仍可用）；若未来被移除，只需替换 `WindowCapture.rawImage(cgID:)` 为 ScreenCaptureKit 实现，其余代码不受影响
- macOS 15+ 会周期性提醒后台使用屏幕录制的 App，属系统行为，可在提醒里关闭月度提醒
- 驻留屏幕外太久、从未被渲染的窗口，其内容会被系统清出缓存，此时缩略图显示为应用图标占位（系统限制，无法强制恢复）

## 诊断模式

排查窗口枚举/截图问题时可用：

```bash
./OpenAltTab.app/Contents/MacOS/OpenAltTab --dump-windows
```

输出写到 `/tmp/openalttab_dump.txt`（CGWindowList、AX 枚举、CG vs ScreenCaptureKit 截图对比），截图样本存到 `/tmp/oat_*.png`。

## License

MIT

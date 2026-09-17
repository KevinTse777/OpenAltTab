# OpenAltTab

macOS 上的 Windows 风格窗口切换器：按住 **⌥ (Option) + Tab**，弹出所有窗口的实时缩略图，松开 ⌥ 即刻切换。

参考 [AltTab](https://alt-tab.xyz)（GitHub: lwouis/alt-tab-macos）自行实现。**AltTab 已于 2026 年转向 Pro 付费模式**（切换器内搜索、外观样式、自动尺寸、多组快捷键均进入付费墙），本项目把这些功能**全部免费实现**——无任何付费墙、无联网、无授权校验。

![macOS](https://img.shields.io/badge/macOS-13%2B-blue) ![构建](https://img.shields.io/badge/SwiftPM-swift%20build-orange) ![版本](https://img.shields.io/badge/version-1.3.0-green)

## 功能

### 核心切换
- ⌥Tab 按住呼出、松开即切换（Windows 手感）；每组窗口一张缩略图（不是每个应用一张），支持已最小化窗口
- 键盘：`Tab` / `Shift+Tab` / `←→↑↓` 循环，`1–9` 数字直选，`Return` 确认，`Esc` 取消
- 鼠标：点击缩略图切换，**悬停即选中**，面板打开时**滚轮/触控板滚动循环**
- `/` 进入搜索：按相关性评分过滤（前缀 > 词边界 > 子串 > 模糊），应用名加权排序；退格删字、Esc 退出
- `⌘Tab` 完全不受影响，仍调用系统原生切换器

### 窗口操作（选中后按下即生效，需按住 ⌥）
- `H` 隐藏↔显示应用　`M` 最小化↔还原窗口　`W` 关闭窗口　`Q` 退出应用　`F` 全屏切换
- 全屏窗口执行最小化/关闭时自动先退全屏再操作（等待动画结束）

### 多组触发键与松开行为
- 内置 ⌥Tab；可启用 ^Tab 第二组；还可用文本规格配置**任意多组**触发键（如 `^⌥Tab`、`` ⌥` ``）
- 松开行为可选：**立即切换**（经典）/ **保持面板**（回车确认）/ **进入搜索**（上游 Pro 的 searchOnRelease 免费版）

### 窗口列表
- 排序：最近聚焦优先 / 按名称；显示范围：所有应用 / 仅前台应用
- 可选过滤：显示最小化窗口、显示 ⌘H 隐藏应用、**仅当前桌面（Space）**的窗口
- **浏览器标签页拆分**：每个标签一张独立卡片，切换时自动点选目标标签（缩略图为当前标签画面）
- **无窗口应用**排在列表末尾，激活即启动/切换
- 每应用例外：指定忽略的应用

### 外观
- 卡片样式：**缩略图 / 纯应用图标 / 纯标题**（上游 Pro 样式，免费）
- **自动尺寸**：按窗口数量分档调整卡片大小（上游 Pro autoSize，免费）
- 皮肤：macOS 毛玻璃 / **Windows 10 扁平风**；浅色/深色/跟随系统
- 图标大小、标题字号、最大行数（1–5 行，超宽自动等比缩卡片）
- 卡片角标：数字直选、同应用窗口数、**隐藏 ⊘ / 全屏 / 最小化 −** 状态角标
- **就地大图预览**：循环时在目标窗口的真实位置浮出高清预览
- **界面多语言**：跟随系统 / 中文 / English

### 系统整合
- 菜单栏常驻：权限状态、偏好设置、清缓存、登录自启（SMAppService）、退出
- 权限全自动化：启动时按需自动触发系统授权弹窗 + 5 秒巡检自动恢复，无需重启 App
- **CLI**：`open "openalttab://动作"` 从命令行/脚本驱动（见下文）

## CLI

```bash
open "openalttab://next"        # 切到相对前台的下一个窗口
open "openalttab://previous"    # 上一个
open "openalttab://show"        # 弹出切换器面板
open "openalttab://hide"        # 关闭面板
open "openalttab://activate/2"  # 切到列表第 2 项
open "openalttab://list"        # 把窗口清单写入 /tmp/openalttab_windows.txt
```

可加 alias：`alias oat='open "openalttab://$1"'`。

## 构建与安装

需要 Xcode 或 Command Line Tools（`xcode-select --install`）。

```bash
cd OpenAltTab
./scripts/make_app.sh        # swift build -c release + 组装 .app + ad-hoc 签名
open OpenAltTab.app
```

建议先 `cp -R OpenAltTab.app /Applications/` 再启动再授权（授权信息与 App 路径/签名绑定，移动后可能需要重新授权一次）。

## 首次使用：授予两项权限

启动后 App 自动弹出对应的系统授权弹窗（缺哪个触发哪个），并每秒检测、5 秒巡检自动恢复：

| 权限 | 用途 | 位置 |
|---|---|---|
| 辅助功能 | 全局监听 ⌥Tab 按键、枚举/切换/窗口操作 | 系统设置 → 隐私与安全性 → 辅助功能 |
| 屏幕录制 | 生成窗口实时缩略图 | 系统设置 → 隐私与安全性 → 屏幕录制 |

不授权屏幕录制时功能仍可用，但缩略图显示为应用图标占位图。屏幕录制授权需在开关打开后**重启 App**（引导窗口有一键重启按钮）。

## 项目结构

```
OpenAltTab/
├── Package.swift                     # SwiftPM，无第三方依赖
├── Sources/OpenAltTab/
│   ├── main.swift                    # 入口：--dump-windows 诊断分支
│   ├── AppDelegate.swift             # 菜单栏、权限自动化、CLI(URL scheme)、多语言重建
│   ├── AppCoordinator.swift          # 事件状态机：呼出/循环/提交/搜索/窗口操作/CLI 接口
│   ├── SwitcherPanel.swift           # NSPanel + 手绘网格（样式/皮肤/角标/悬停）
│   ├── PreviewPanel.swift            # 选中窗口的就地大图预览
│   ├── WindowEnumerator.swift        # AX 枚举：标签拆分/幽灵窗口过滤/无窗口应用/排序
│   ├── WindowCapture.swift           # SC 截图 + 双层缓存 + 预览抓拍
│   ├── HWCapture.swift               # SkyLight 私有 API（dlopen 隔离）：CGSHWCaptureWindowList 截图 + CGS Space 查询
│   ├── Search.swift                  # 搜索分层相关性评分
│   ├── CacheWarmer.swift             # 应用激活 2 秒后预热其前台窗口
│   ├── AppSettings.swift             # UserDefaults 偏好全集
│   ├── SupportWindows.swift          # 权限引导窗口、偏好设置窗口
│   ├── Permissions.swift             # 权限检测/按需注册
│   ├── L10n.swift                    # 中英双语词条
│   ├── Keys.swift                    # 虚拟键码 + 触发键规格解析
│   └── DebugDump.swift               # --dump-windows 诊断
├── docs/对比分析.md                   # 与上游 alt-tab-macos 的源码级对比（Pro 付费墙/差距/路线图）
├── HANDOFF.md                        # 交接文档：架构/教训/待办/约定
└── scripts/make_app.sh               # 编译 + 组装 .app（含 URL scheme 注册）+ ad-hoc 签名
```

### 实现要点

- **缩略图缓存体系**：内存 LRU（256 条）+ 磁盘持久化（`~/Library/Caches/com.openalttab.macos/thumbs`，按"应用+窗口标题"键存长边 640px 高清版）双层；写入时机：面板打开瞬间的前台窗口、切换成功后 0.8s/2.2s 两轮重拍、CacheWarmer 激活预热
- **截图管线**：ScreenCaptureKit 主路径（偶发 -3811 自动重试一次）→ SkyLight `CGSHWCaptureWindowList` 兜底（**能拍最小化窗口**，fullSize 位可规避台前调度倾斜；dlopen 惰性绑定，符号缺失自动回退）→ 旧 `CGWindowListCreateImage` 最后兜底；台前调度"缩小+倾斜"条目通过 SC/CG 尺寸比识别并拒绝实拍，改用"最后所见"磁盘缓存；纯色空白帧检测（8×8 采样）
- **按键捕获（防吞字设计）**：`CGEventTap` 事件回调里绝不做慢操作，AX 全部走后台队列；触发修饰键松开后非导航键一律放行并关面板；窗口操作键必须按住 ⌥ 才生效；tap 被系统禁用时自动恢复
- **窗口枚举**：AX API + `_AXUIElementGetWindow` 映射 CGWindowID（0.35s 消息超时）；幽灵窗口规则（AXDesktop 子角色 + layer0 缺失即丢弃）
- **私有 API 隔离**：SkyLight 符号全部经 dlopen+dlsym 惰性绑定（SwiftPM 不链接私有框架，直接引用会在启动时崩溃），失败自动降级到公开 API 路径

## 已知限制

- 标签页拆分下，每个标签卡片的缩略图都是"当前激活标签"的画面（系统只渲染当前标签）
- Space 过滤依赖 SkyLight 私有查询，若未来系统移除相关符号会自动退化为显示全部 Space
- `CGWindowListCreateImage` 已被 Apple 弃用（目前仍可用），仅作最后兜底
- macOS 15+ 会周期性提醒后台使用屏幕录制的 App，属系统行为
- 驻留屏幕外太久、从未被渲染的窗口，其内容会被系统清出缓存，此时缩略图显示为应用图标占位

## 诊断模式

```bash
./OpenAltTab.app/Contents/MacOS/OpenAltTab --dump-windows
```

输出写到 `/tmp/openalttab_dump.txt`（CGWindowList、AX 枚举、CG vs ScreenCaptureKit 截图对比），截图样本存到 `/tmp/oat_*.png`。

## 文档

- [HANDOFF.md](HANDOFF.md)——开发交接：架构、踩坑教训、待办、提交约定
- [docs/对比分析.md](docs/对比分析.md)——与上游 alt-tab-macos 的逐项对比、Pro 付费墙清单、技术借鉴点

## License

MIT

# OpenAltTab 交接提示词（HANDOFF）

> 新会话开始时：先读完本文件，再按「待办」顺序工作。项目位置：`/Users/tse/Projects/OpenAltTab`（git 管理）。

## 项目是什么

macOS 的 Windows 风格窗口切换器（参考 GitHub 的 https://github.com/lwouis/alt-tab-macos，免费无付费墙自研实现）。
按住 **⌥Tab** 弹出全部窗口缩略图，松开 ⌥ 切换。用户环境：**macOS 26.6 (Tahoe) / Apple Silicon / Xcode Swift 6.2**。
用户核心诉求：尽量完整实现 AltTab 的功能；**迭代尽量不需要人工介入**（流程尽量自动化）。

## 构建与调试

```bash
cd ~/Projects/OpenAltTab
./scripts/make_app.sh          # swift build -c release + 组装 .app + ad-hoc 签名 + 生成图标
open OpenAltTab.app
# 诊断模式（枚举 + CG vs SC 截图对比，结果在 /tmp/openalttab_dump.txt 和 /tmp/oat_*.png）：
./OpenAltTab.app/Contents/MacOS/OpenAltTab --dump-windows
```

## 架构（Sources/OpenAltTab/）

| 文件 | 职责 |
|---|---|
| main.swift | 入口；`--dump-windows` 诊断分支 |
| AppCoordinator | 事件状态机：触发/循环/提交/窗口操作 |
| SwitcherPanel + SwitcherGridView | 无边框 NSPanel（不激活、全屏 Space 可见）+ 手绘缩略图网格 |
| WindowEnumerator | AX 枚举窗口；`_AXUIElementGetWindow` 映射 CGWindowID；0.35s 消息超时 |
| WindowCapture | 截图管线 + 内存/磁盘双层缓存 + `refresh(delay:)` 重拍 |
| CacheWarmer | 监听应用激活，~2s 后自动补拍其前台窗口（渐进式填缓存） |
| SupportWindows | 权限引导窗口（重新注册/重启按钮）、偏好设置窗口 |
| Permissions / AppDelegate / AppSettings / Keys | 权限检测、菜单栏、偏好、键码 |

## 关键教训（务必遵守，都是踩过的坑）

1. **台前调度（Stage Manager）**：左侧条目窗口被合成器"缩小+3D倾斜"，**任何截图 API**（ScreenCaptureKit、CGWindowListCreateImage）拿到的都是倾斜画面。识别：`AX逻辑尺寸/CG实际边界 < 0.67` 或 `SC帧/CG边界 > 1.5` → 拒绝实拍，显示"最后所见"缓存（磁盘持久化）。
2. **驻留屏幕外太久的窗口**渲染缓存被系统清除，截图是严格纯色（灰/黑）→ `isBlank` 单色检测（阈值 6）视为无效。
3. **事件回调严禁慢操作**：曾在 CGEventTap 回调里同步跑 AX 枚举 → tap 超时被系统禁用 → 面板状态卡死 → 吞掉全系统按键（用户打不了字）。防吞字三原则：慢操作全后台队列；⌥松开后非导航键一律放行并关面板；H/M/W/Q 需按住 ⌥ 才生效。
4. **TCC 权限**：ad-hoc 重编译 cdhash 变化 → 授权失效。`CGRequestScreenCaptureAccess` 对同一签名只弹一次，手动删条目不清"已询问"标记 → 必须 `tccutil reset ScreenCapture com.openalttab.macos` 后再 request。屏幕录制授权对运行中进程不生效，**必须重启 App**。macOS 26 SDK：`AXUIElementCopyAttributeValue` 只有 3 参数（无 error 出参）；`NSBeep` 不可用（用 `NSSound.beep()`）。
5. **引号钩子**：环境里有格式化钩子会把源码直引号改成中文弯引号（“”），导致 `unicode curly quote` 编译错误。修法：`perl -i -pe 's/\xe2\x80\x9c/"/g; s/\xe2\x80\x9d/"/g' Sources/OpenAltTab/*.swift` 然后立即编译。
6. 面板打开期间事件 tap 吞掉全部按键是**有意设计**（防止误输入后台窗口），放行阀门必须保留。

## 待办

> 2026-09-17：原 7 项待办已全部完成（见下方"已完成 1.1.0"，提交 804f17c…cbd538d）。**尚未做真机人工测试**——用户明确说测试可以后面再做；下次会话可先实测再修问题。
> 2026-09-17：已克隆上游 lwouis/alt-tab-macos 做过源码级对比，详见 **`docs/对比分析.md`**（含上游 Pro 付费墙清单、逐项功能对比、技术借鉴点、P0–P2 路线图）。上游已 Pro 化：切换器内搜索、图标+标题样式、自动尺寸、第 2–9 组快捷键都被付费墙挡住——本项目免费实现正是差异化价值。

1. 【test】真机验证 1.1.0：访达窗口数、搜索（/ 输入、⌥ 组合键字符是否正常）、多屏偏好、行数上限/角标/悬停、启动自动权限弹窗。
2. 【known-risk】搜索取字符用的是"副本清掉 ⌘⌃⌥ 再取 Unicode"（Keys.swift `SearchInput`），个别布局/死键可能取不到字符；`event.copy()` 在 App 未激活时悬停 mouseMoved 是否送达也未验证。
3. 【feat-P0】按 `docs/对比分析.md` 路线图：窗口操作补全（F 全屏切换、H/M 改切换语义）、搜索相关性评分排序、隐藏/全屏/最小化三态角标、CGSHWCaptureWindowList 兜底拍最小化窗口（私有 API 隔离封装）。
4. 【feat-P1】第二组快捷键与松开行为偏好；Space/屏幕/隐藏窗口过滤；窗口排序偏好；纯图标/纯标题卡片样式。

## 已完成 1.1.0（提交记录）

- fix: 窗口枚举过滤访达桌面"窗口"（AXDesktop 子角色）与幽灵窗口（AX 有 CGID 但 CGWindowList layer0 查无即丢弃）
- fix: 权限重新注册按需执行（只处理缺失项，只开对应设置面板）
- feat: 启动自动执行按需权限注册（`autoRegisterDone` 标记防重复 reset）
- feat: 面板内搜索模式（/ 进入；副本去 ⌘⌃⌥ 后取字符；退格删字、空则退出；Enter 提交、Esc 退出搜索；Tab/方向键仍循环；`allItems`/`items` 分离；截图回调按对象引用赋值避免过滤后索引错位）
- feat: 面板出现屏幕偏好（目标窗口所在屏幕 / 鼠标所在屏幕）
- feat: 外观偏好（图标大小、标题字号、最大行数 1–5 行自动缩卡片、同应用多窗口角标、悬停选中）
- chore: 版本 1.1.0；关于面板读 `CFBundleShortVersionString`

## 迁移注意（已踩坑）

- 旧 `.build/` 缓存带着旧绝对路径（`~/.zcode/workspace/default/...`），迁移后 release 构建报 `PCH was compiled with module cache path ...` / `missing required module 'SwiftShims'`——**删掉 `.build` 重跑即可**（2026-09-17 已处理）。

## 约定

- 每个逻辑改动一个 commit，中文 commit message。
- 改完源码：先 perl 归一化引号，再 `swift build`，再 `./scripts/make_app.sh`。
- 不要随意 killall 正在运行的实例：用户授权绑定在当前运行的二进制上，重启后需要走一遍重新注册（现在已高度自动化：弹窗自动出现，用户只需点确认和开关）。
- 迁移说明：项目已从 `~/.zcode/workspace/default/OpenAltTab` 迁移到 `~/Projects/OpenAltTab`；旧路径已不存在。

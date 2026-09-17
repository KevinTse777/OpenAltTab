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

## 待办（按用户最新反馈排序）

1. 【bug】访达 2 个窗口显示成 3 个（多出的图标是访达的桌面"窗口"）。
   修法：`WindowEnumerator.describe()` 中 (a) subrole 过滤加 `"AXDesktop"`；(b) 幽灵窗口规则：`hasCGID && !minimized && cgFrames[cgID] == nil` 时丢弃——真实用户窗口必然在 CGWindowList layer 0 里（最小化和其他 Space 也在）。
2. 【bug】重新注册逻辑不正确：当前按钮无条件 `reset+request`，会把有效授权也清掉。改成按需：仅 `!accessibilityGranted` 时 `promptAccessibilityRegistration()`；仅 `!screenRecordingGranted` 时 `resetScreenRecordingRegistration()+requestScreenRecording()`；只打开缺失项对应的设置面板。
3. 【feat】启动时自动触发注册（用户不必找按钮）：`AppDelegate.showPermissionFlow()` 里加 `autoRegisterDone` 标记，首次自动执行上面的按需注册，系统弹窗自动出现。
4. 【feat】搜索模式：面板打开时按 `/` 进入；用 `CGEventKeyboardGetUnicodeString` 取输入追加查询；Backspace（键码 51）删除、空则退出；Enter 提交、Esc 退出搜索；Tab/方向键仍循环。数据侧 `allItems`/`items`（过滤后）分离；`SwitcherGridView.update` 增加 `searchLine: String?` 参数（顶部 30pt 显示"搜索: x n/m"，总高相应增加）；`scheduleThumbnails` 的完成回调改为 `item.thumbnail = image`（类引用直接赋值，避免过滤后索引错位）。
5. 【feat】面板出现位置偏好：目标窗口所在屏幕 / 鼠标所在屏幕（AppSettings + PrefsWindow + `targetScreen()`）。
6. 【feat-parity】对照 alt-tab.xyz 补齐：应用图标大小偏好、标题字体大小、多行上限、应用多窗口角标、悬停高亮等。
7. 【chore】版本号升 1.1.0（`scripts/make_app.sh` 的 Info.plist + About 面板改为读 `CFBundleShortVersionString`）。

## 约定

- 每个逻辑改动一个 commit，中文 commit message。
- 改完源码：先 perl 归一化引号，再 `swift build`，再 `./scripts/make_app.sh`。
- 不要随意 killall 正在运行的实例：用户授权绑定在当前运行的二进制上，重启后需要走一遍重新注册（现在已高度自动化：弹窗自动出现，用户只需点确认和开关）。
- 迁移说明：项目已从 `~/.zcode/workspace/default/OpenAltTab` 迁移到 `~/Projects/OpenAltTab`；旧路径已不存在。

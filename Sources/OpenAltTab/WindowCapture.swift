import AppKit
import CoreGraphics
import CryptoKit
import ScreenCaptureKit

/// 后台线程捕获窗口缩略图，带内存 + 磁盘双层缓存。
///
/// 台前调度（Stage Manager）策略：
/// - 左侧条目里的窗口被系统以"缩小 + 3D 倾斜"合成显示，任何截图 API 拿到的都是倾斜画面
///   （SC 逻辑尺寸 ÷ CG 实际边界 > 1.5 即识别为这类窗口）→ 拒绝实拍，改用缓存里
///   "最后一次见到的内容"
/// - 屏幕外驻留太久的窗口，渲染缓存被系统清除，只能截到纯色占位（灰/黑）→ 视为无效
/// - 窗口每次成为前台后自动重拍（AppCoordinator 触发 refresh），缓存随之持续更新
///
/// 捕获顺序：内存缓存 → 磁盘缓存（跨重启保留）→ ScreenCaptureKit 实拍 → 旧 API 兜底 → nil(占位图)
enum WindowCapture {
    private static let queue = DispatchQueue(label: "OpenAltTab.capture", qos: .userInitiated)
    private static var cache: [CGWindowID: (image: CGImage, at: Date)] = [:]
    private static let cacheLimit = 256
    private static var saveCounter = 0

    /// ScreenCaptureKit 窗口列表缓存（带 TTL，避免每次截图都重新枚举）
    @available(macOS 14.0, *)
    private static let scCache = SCContentCache()

    /// 收起的窗口内容按此长边像素渲染，保证清晰
    private static let targetLongEdge = 960.0

    /// 清空内存与磁盘缩略图缓存（菜单栏手动触发）
    static func clearAllCaches() {
        queue.async {
            cache.removeAll()
            saveCounter = 0
            if let dir = diskDir {
                try? FileManager.default.removeItem(at: dir)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
    }

    static func cached(cgID: CGWindowID) -> CGImage? {
        queue.sync { cache[cgID]?.image }
    }

    /// 面板每次打开时调用，保证窗口列表新鲜（新建/关闭的窗口不遗漏）
    static func invalidateWindowList() {
        if #available(macOS 14.0, *) {
            Task { await scCache.invalidate() }
        }
    }

    static func fetch(cgID: CGWindowID, cardSize: NSSize, diskKey: String, cgFrame: CGRect?,
                      axSize: CGSize?, completion: @escaping (CGImage?) -> Void) {
        queue.async {
            if let hit = cache[cgID] {
                DispatchQueue.main.async { completion(hit.image) }
                return
            }
            if let img = loadFromDisk(key: diskKey) {
                let small = downscale(img, box: cardSize)
                remember(cgID: cgID, image: small)
                DispatchQueue.main.async { completion(small) }
                return
            }
            fetchLive(cgID: cgID, cardSize: cardSize, diskKey: diskKey, cgFrame: cgFrame,
                      axSize: axSize, completion: completion)
        }
    }

    /// 重拍某窗口并更新缓存。切换后延迟调用（等渲染/动画结束）；delay=0 表示立即拍
    static func refresh(cgID: CGWindowID, cardSize: NSSize, diskKey: String, cgFrame: CGRect?,
                        axSize: CGSize?, delay: TimeInterval = 0.8) {
        queue.asyncAfter(deadline: .now() + delay) {
            cache.removeValue(forKey: cgID)
            fetchLive(cgID: cgID, cardSize: cardSize, diskKey: diskKey, cgFrame: cgFrame,
                      axSize: axSize) { _ in }
        }
    }

    /// 在 capture 队列上调用：实拍并写入双层缓存
    private static func fetchLive(cgID: CGWindowID, cardSize: NSSize, diskKey: String,
                                  cgFrame: CGRect?, axSize: CGSize?,
                                  completion: @escaping (CGImage?) -> Void) {
        // 截图瞬间重新查询实际显示边界：枚举到截图之间窗口可能刚被台前调度缩放/收起
        let displayBounds = currentCGBounds(cgID: cgID) ?? cgFrame

        // 台前调度条目窗口：合成器把整窗缩小+倾斜显示，任何 API 实拍必然倾斜。
        // 用 AX 逻辑尺寸与实际显示边界之比拦截（窗口服务器与辅助功能两套独立数据源）
        if let ax = axSize, ax.width > 4, ax.height > 4,
           let disp = displayBounds, disp.width > 4, disp.height > 4 {
            if disp.width / ax.width < 0.67 || disp.height / ax.height < 0.67 {
                DispatchQueue.main.async { completion(nil) }
                return
            }
        }

        let done: (CGImage?) -> Void = { image in
            guard let image else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let small = downscale(image, box: cardSize)
            remember(cgID: cgID, image: small)
            saveToDisk(key: diskKey, image: small)
            DispatchQueue.main.async { completion(small) }
        }

        if #available(macOS 14.0, *) {
            scCapture(cgID: cgID, cgFrame: displayBounds) { scImage, skipCGFallback in
                if let scImage {
                    done(scImage)
                } else if !skipCGFallback, let cg = rawImage(cgID: cgID), !isBlank(cg) {
                    done(cg)
                } else {
                    done(nil)
                }
            }
        } else if let cg = rawImage(cgID: cgID), !isBlank(cg) {
            done(cg)
        } else {
            done(nil)
        }
    }

    private static func remember(cgID: CGWindowID, image: CGImage) {
        if cache.count >= cacheLimit,
           let oldest = cache.min(by: { $0.value.at < $1.value.at })?.key {
            cache.removeValue(forKey: oldest)
        }
        cache[cgID] = (image, Date())
    }

    // MARK: - ScreenCaptureKit

    private enum SCOutcome {
        case image(CGImage)
        case notFound
        /// 台前调度条目窗口：合成器缩小+倾斜显示，实拍必然带倾斜
        case scaledEntry
    }

    @available(macOS 14.0, *)
    private static func scCapture(cgID: CGWindowID, cgFrame: CGRect?,
                                  completion: @escaping (CGImage?, _ skipCGFallback: Bool) -> Void) {
        Task.detached(priority: .high) {
            var outcome = await attempt(cgID: cgID, cgFrame: cgFrame)
            if case .notFound = outcome {
                // SC 偶发瞬时流错误（-3811），稍等重试一次
                try? await Task.sleep(nanoseconds: 150_000_000)
                outcome = await attempt(cgID: cgID, cgFrame: cgFrame)
            }
            switch outcome {
            case .image(let img):
                completion(isBlank(img) ? nil : img, false)
            case .notFound:
                completion(nil, false)
            case .scaledEntry:
                completion(nil, true)
            }
        }
    }

    @available(macOS 14.0, *)
    private static func attempt(cgID: CGWindowID, cgFrame: CGRect?) async -> SCOutcome {
        do {
            let content = try await scCache.shared(force: false)
            guard let window = content.windows.first(where: { $0.windowID == cgID }) else {
                // 缓存的窗口列表过期（新开/刚切换的窗口），强制刷新再试一次
                let fresh = try await scCache.shared(force: true)
                guard let w2 = fresh.windows.first(where: { $0.windowID == cgID }) else {
                    return .notFound
                }
                return await snapClassified(w2, cgFrame: cgFrame)
            }
            return await snapClassified(window, cgFrame: cgFrame)
        } catch {
            return .notFound
        }
    }

    @available(macOS 14.0, *)
    private static func snapClassified(_ window: SCWindow, cgFrame: CGRect?) async -> SCOutcome {
        if let cg = cgFrame, cg.width > 4, cg.height > 4,
           window.frame.width / cg.width > 1.5, window.frame.height / cg.height > 1.5 {
            return .scaledEntry
        }
        do {
            return .image(try await snap(window))
        } catch {
            return .notFound
        }
    }

    @available(macOS 14.0, *)
    private static func snap(_ window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let w = max(1, window.frame.width)
        let h = max(1, window.frame.height)
        if w >= h {
            config.width = Int(targetLongEdge)
            config.height = max(1, Int(targetLongEdge * h / w))
        } else {
            config.height = Int(targetLongEdge)
            config.width = max(1, Int(targetLongEdge * w / h))
        }
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    @available(macOS 14.0, *)
    private actor SCContentCache {
        private var content: SCShareableContent?
        private var fetchedAt = Date.distantPast

        func shared(force: Bool) async throws -> SCShareableContent {
            if !force, let c = content, Date().timeIntervalSince(fetchedAt) < 10 {
                return c
            }
            let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            content = c
            fetchedAt = Date()
            return c
        }

        func invalidate() {
            content = nil
            fetchedAt = .distantPast
        }
    }

    // MARK: - 磁盘缓存

    private static let diskDir: URL? = {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("com.openalttab.macos", isDirectory: true)
            .appendingPathComponent("thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func diskURL(for key: String) -> URL? {
        guard let dir = diskDir, !key.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent("\(digest).png")
    }

    private static func loadFromDisk(key: String) -> CGImage? {
        guard let url = diskURL(for: key),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return isBlank(img) ? nil : img
    }

    private static func saveToDisk(key: String, image: CGImage) {
        guard let url = diskURL(for: key) else { return }
        // 磁盘统一存高清版（长边 640），显示时再按当前卡片尺寸缩放，换尺寸不会糊
        let rep = NSBitmapImageRep(cgImage: downscaleToLongEdge(image, 640))
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url, options: .atomic)
        }
        saveCounter += 1
        if saveCounter % 24 == 0 { pruneDisk() }
    }

    private static func pruneDisk(keep: Int = 150) {
        guard let dir = diskDir,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > keep else { return }
        let sorted = files.sorted { a, b in
            let d1 = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let d2 = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return d1 < d2
        }
        for f in sorted.prefix(files.count - keep) {
            try? FileManager.default.removeItem(at: f)
        }
    }

    // MARK: - 图像工具

    /// 旧 API 兜底：对屏外整窗截图（能拍到部分台前调度条目窗口的最后内容）
    static func rawImage(cgID: CGWindowID) -> CGImage? {
        CGWindowListCreateImage(CGRect.null, .optionIncludingWindow, cgID,
                                [.bestResolution, .boundsIgnoreFraming])
    }

    /// 截图瞬间查询窗口在窗口服务器里的实际显示边界（台前调度条目窗口是缩小后的尺寸）
    private static func currentCGBounds(cgID: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for w in list {
            guard w[kCGWindowNumber as String] as? Int == Int(cgID),
                  let b = w[kCGWindowBounds as String] as? [String: Any] else { continue }
            return CGRect(dictionaryRepresentation: b as CFDictionary)
        }
        return nil
    }

    /// 等比缩放到指定长边像素（只缩不放），用于磁盘缓存的高清版
    private static func downscaleToLongEdge(_ image: CGImage, _ longEdge: Int) -> CGImage {
        let long = max(image.width, image.height)
        guard long > longEdge else { return image }
        let scale = Double(longEdge) / Double(long)
        let w = max(1, Int(Double(image.width) * scale))
        let h = max(1, Int(Double(image.height) * scale))
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    /// 8x8 降采样：单色画面（纯黑/纯灰/纯白等）说明渲染缓存已被系统清除，是无效内容
    static func isBlank(_ image: CGImage) -> Bool {
        let w = 8
        let h = 8
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return false }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var minR = 255, maxR = 0, minG = 255, maxG = 0, minB = 255, maxB = 0
        for i in 0..<(w * h) {
            let r = Int(px[i * 4]), g = Int(px[i * 4 + 1]), b = Int(px[i * 4 + 2])
            minR = min(minR, r); maxR = max(maxR, r)
            minG = min(minG, g); maxG = max(maxG, g)
            minB = min(minB, b); maxB = max(maxB, b)
        }
        // 阈值收紧到 6：被清除的渲染缓存是严格纯色（方差≈0），
        // 真实窗口截图几乎必然有抗锯齿/渐变带来的细微波动，避免把深色窗口误判成空白
        return maxR - minR < 6 && maxG - minG < 6 && maxB - minB < 6
    }

    /// 整窗截图可能非常大（视网膜屏每张几 MB），先按卡片尺寸 2x 降采样再进缓存
    private static func downscale(_ image: CGImage, box: NSSize) -> CGImage {
        let targetW = max(1, Int(box.width * 2))
        let targetH = max(1, Int(box.height * 2))
        let scale = min(Double(targetW) / Double(image.width), Double(targetH) / Double(image.height))
        let w = max(1, Int(Double(image.width) * scale))
        let h = max(1, Int(Double(image.height) * scale))
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}

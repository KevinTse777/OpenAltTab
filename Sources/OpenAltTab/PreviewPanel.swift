import AppKit

/// 选中窗口的就地大图预览（对齐上游 PreviewPanel）：
/// 浮在目标窗口的真实屏幕位置上，循环时实时跟随。
/// 先用缩略图放大显示保证即时性，后台抓拍的高清帧到位后热替换。
final class PreviewPanel: NSPanel {
    static let shared = PreviewPanel()

    private let imageView = NSImageView(frame: .zero)
    /// 正在展示的窗口编号：高清抓拍回来时校验，避免换图错位
    private var pendingID: CGWindowID?

    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 4
        imageView.layer?.masksToBounds = true
        contentView = imageView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(item: WindowItem) {
        // cgFrame 是屏幕左上原点坐标系，转 NSScreen 左下原点
        guard let cgFrame = item.cgFrame ?? item.screenFrame.map({ f -> CGRect in
            let screenH = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY
                ?? NSScreen.main?.frame.maxY ?? 900
            return CGRect(x: f.minX, y: screenH - f.maxY, width: f.width, height: f.height)
        }), cgFrame.width > 8, cgFrame.height > 8 else {
            hide()
            return
        }
        setFrame(cgFrame.insetBy(dx: -4, dy: -4), display: false)
        let id = item.cgWindowID
        pendingID = id
        if let thumb = item.thumbnail {
            imageView.image = NSImage(cgImage: thumb,
                                      size: NSSize(width: thumb.width, height: thumb.height))
        } else {
            imageView.image = nil
        }
        alphaValue = 1
        orderFrontRegardless()
        guard let id else { return }
        WindowCapture.fetchPreview(cgID: id) { [weak self] image in
            guard let self, self.pendingID == id, self.isVisible, let image else { return }
            self.imageView.image = NSImage(cgImage: image,
                                           size: NSSize(width: image.width, height: image.height))
        }
    }

    func hide() {
        pendingID = nil
        imageView.image = nil
        alphaValue = 0
        orderOut(nil)
    }
}

import AppKit

/// 切换器主面板：无边框、不激活、可在全屏 Space 之上显示
final class SwitcherPanel: NSPanel {
    let grid = SwitcherGridView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        worksWhenModal = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        contentView = effect
        grid.frame = effect.bounds
        effect.addSubview(grid)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func showCentered(on screen: NSScreen, size: NSSize) {
        let vf = screen.visibleFrame
        let w = min(size.width, vf.width - 24)
        let h = min(size.height, vf.height - 24)
        let frame = NSRect(x: vf.midX - w / 2, y: vf.midY - h / 2 + 12, width: w, height: h)
        setFrame(frame, display: false)
        contentView?.frame = NSRect(origin: .zero, size: NSSize(width: w, height: h))
        grid.frame = contentView!.bounds
        alphaValue = 1
        orderFrontRegardless()
    }

    func dismissPanel() {
        alphaValue = 0
        orderOut(nil)
    }
}

/// 缩略图网格视图，全部用 draw(_:) 手绘
final class SwitcherGridView: NSView {
    struct Card {
        let frame: CGRect
        let thumb: CGRect
        let title: CGRect
    }

    private(set) var items: [WindowItem] = []
    private(set) var selection = 0
    private(set) var perRow = 1
    private var cards: [Card] = []
    /// 顶部搜索行内容（搜索模式才显示）
    private var searchLine: String?
    /// 同一应用当前展示的窗口数（多窗口角标用），键为 bundleId 或应用名
    private var appCounts: [String: Int] = [:]
    private var trackingInstalled = false
    /// 递增计数：面板关闭后用于丢弃仍在路上的异步截图回调
    var generation = 0
    var onPick: ((Int) -> Void)?

    private let inset: CGFloat = 16
    private let spacing: CGFloat = 12
    private let titleHeight: CGFloat = 30
    private let cardPadding: CGFloat = 8
    private let searchLineHeight: CGFloat = 30

    @discardableResult
    func update(items: [WindowItem], selection: Int, thumbSize: NSSize, maxWidth: CGFloat,
                searchLine: String? = nil) -> NSSize {
        self.items = items
        self.selection = min(max(0, selection), max(0, items.count - 1))
        self.searchLine = searchLine
        generation += 1
        cards.removeAll()

        let searchH: CGFloat = searchLine == nil ? 0 : searchLineHeight

        // 搜索无结果：只留搜索行 + 一行提示
        guard !items.isEmpty else {
            let size = NSSize(width: max(280, min(maxWidth, 340)), height: searchH + 52)
            setFrameSize(size)
            needsDisplay = true
            return size
        }

        let cardW = thumbSize.width + cardPadding * 2
        let style = AppSettings.shared.cardStyle
        let cardH: CGFloat
        switch style {
        case .thumbnails: cardH = thumbSize.height + titleHeight + cardPadding * 2
        case .appIcons: cardH = cardW // 正方形，大图标居中
        case .titles: cardH = titleHeight + cardPadding * 2
        }
        let availW = max(cardW, maxWidth - inset * 2)
        let count = items.count
        var per = max(1, Int((availW + spacing) / (cardW + spacing)))
        // 最大行数偏好：行数超过上限时增加每行卡片数
        let cap = AppSettings.shared.maxRows
        if cap > 0 {
            let naturalRows = Int(ceil(Double(count) / Double(per)))
            if naturalRows > cap {
                per = max(1, Int(ceil(Double(count) / Double(cap))))
            }
        }
        perRow = per
        let cols = min(count, per)
        let rows = Int(ceil(Double(count) / Double(per)))
        // 行数上限迫使每行卡片变多时，等比缩小卡片，保证面板不超出屏幕宽度
        let shrink = min(1, ((availW - spacing * CGFloat(per - 1)) / CGFloat(per)) / cardW)
        let drawCardW = cardW * shrink
        let drawCardH = cardH * shrink
        let drawTitleH = titleHeight * shrink
        let drawThumbW = thumbSize.width * shrink
        let drawThumbH = thumbSize.height * shrink
        let gridW = CGFloat(cols) * drawCardW + CGFloat(cols - 1) * spacing
        let gridH = CGFloat(rows) * drawCardH + CGFloat(rows - 1) * spacing
        let size = NSSize(width: gridW + inset * 2, height: gridH + searchH + inset * 2)

        // 同应用多窗口计数（标题栏角标）
        var counts: [String: Int] = [:]
        for it in items { counts[it.app.bundleIdentifier ?? it.appName, default: 0] += 1 }
        appCounts = counts

        for i in 0..<count {
            let r = i / per
            let c = i % per
            let colsInRow = min(per, count - r * per)
            let rowW = CGFloat(colsInRow) * drawCardW + CGFloat(colsInRow - 1) * spacing
            let x0 = inset + (gridW - rowW) / 2
            // 非翻转坐标系：搜索行在最上方，第 0 行卡片紧随其下
            let y = size.height - inset - searchH - CGFloat(r + 1) * drawCardH - CGFloat(r) * spacing
            let frame = CGRect(x: x0 + CGFloat(c) * (drawCardW + spacing), y: y,
                               width: drawCardW, height: drawCardH)
            let thumb: CGRect
            let title: CGRect
            switch style {
            case .thumbnails:
                thumb = CGRect(x: frame.minX + cardPadding * shrink,
                               y: frame.maxY - cardPadding * shrink - drawThumbH,
                               width: drawThumbW, height: drawThumbH)
                title = CGRect(x: frame.minX + cardPadding * shrink,
                               y: frame.minY + cardPadding * shrink,
                               width: frame.width - cardPadding * shrink * 2, height: drawTitleH)
            case .appIcons:
                thumb = frame.insetBy(dx: cardPadding * shrink, dy: cardPadding * shrink)
                title = frame
            case .titles:
                thumb = frame
                title = frame.insetBy(dx: cardPadding * shrink, dy: cardPadding * shrink)
            }
            cards.append(Card(frame: frame, thumb: thumb, title: title))
        }

        setFrameSize(size)
        needsDisplay = true
        return size
    }

    func setSelection(_ index: Int) {
        selection = min(max(0, index), max(0, items.count - 1))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

        // 顶部搜索行
        if let sl = searchLine {
            let ps = NSMutableParagraphStyle()
            ps.lineBreakMode = .byTruncatingTail
            let rect = CGRect(x: inset, y: bounds.height - searchLineHeight,
                              width: bounds.width - inset * 2, height: searchLineHeight - 4)
            sl.draw(in: rect, withAttributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: ps,
            ])
        }

        // 空态：无窗口 / 搜索无匹配
        if items.isEmpty {
            let text = searchLine == nil ? "没有可切换的窗口" : "无匹配窗口"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let ts = text.size(withAttributes: attrs)
            let centerY = searchLine == nil ? bounds.midY : (bounds.height - searchLineHeight) / 2
            text.draw(at: NSPoint(x: (bounds.width - ts.width) / 2, y: centerY - ts.height / 2),
                      withAttributes: attrs)
            return
        }

        for (i, item) in items.enumerated() {
            guard i < cards.count else { break }
            drawCard(item, card: cards[i], index: i, selected: i == selection, dark: dark, ctx: ctx)
        }
    }

    /// 缩略图角落的状态徽章：小圆角底 + 着色 SF Symbol
    private func drawStateChip(_ symbol: String, corner: NSPoint, dark: Bool) {
        let side = CGFloat(18)
        let rect = CGRect(origin: corner, size: CGSize(width: side, height: side))
        (dark ? NSColor.black.withAlphaComponent(0.55) : NSColor.white.withAlphaComponent(0.75)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        guard var img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return }
        img = img.withSymbolConfiguration(.init(pointSize: 10, weight: .medium)) ?? img
        let tint: NSColor = dark ? .white : .black
        let inner = rect.insetBy(dx: 3.5, dy: 3.5)
        let tinted = NSImage(size: inner.size, flipped: false) { _ in
            tint.set()
            img.draw(in: inner)
            return true
        }
        tinted.draw(in: inner)
    }

    private func drawCard(_ item: WindowItem, card: Card, index: Int, selected: Bool, dark: Bool, ctx: CGContext) {
        let style = AppSettings.shared.cardStyle
        let cardPath = NSBezierPath(roundedRect: card.frame, xRadius: 12, yRadius: 12)

        ctx.saveGState()
        cardPath.addClip()

        let cardFill: NSColor
        if dark {
            cardFill = NSColor.white.withAlphaComponent(selected ? 0.16 : 0.07)
        } else {
            cardFill = NSColor.black.withAlphaComponent(selected ? 0.10 : 0.05)
        }
        cardFill.setFill()
        ctx.fill(card.frame)

        // 内容区：缩略图 / 纯大图标 / 无（纯标题）
        if style == .thumbnails {
            let thumbPath = NSBezierPath(roundedRect: card.thumb, xRadius: 8, yRadius: 8)
            ctx.saveGState()
            thumbPath.addClip()
            if let cg = item.thumbnail {
                ctx.interpolationQuality = .high
                let s = min(card.thumb.width / CGFloat(cg.width), card.thumb.height / CGFloat(cg.height))
                let w = CGFloat(cg.width) * s
                let h = CGFloat(cg.height) * s
                ctx.draw(cg, in: CGRect(x: card.thumb.midX - w / 2, y: card.thumb.midY - h / 2,
                                        width: w, height: h))
            } else {
                (dark ? NSColor.white.withAlphaComponent(0.04) : NSColor.black.withAlphaComponent(0.03)).setFill()
                ctx.fill(card.thumb)
                if let icon = item.app.icon {
                    let side = min(card.thumb.width, card.thumb.height) * 0.42
                    icon.draw(in: CGRect(x: card.thumb.midX - side / 2, y: card.thumb.midY - side / 2,
                                         width: side, height: side))
                }
            }
            ctx.restoreGState()
        } else if style == .appIcons, let icon = item.app.icon {
            let side = min(card.thumb.width, card.thumb.height) * 0.62
            icon.draw(in: CGRect(x: card.thumb.midX - side / 2, y: card.thumb.midY - side / 2,
                                 width: side, height: side))
        }

        // 状态角标：隐藏 ⊘ / 全屏 ↗↙ / 最小化 −（对齐上游 TileStatusIcons）
        let anchor = style == .thumbnails ? card.thumb : card.frame
        var chipX = anchor.maxX - 24
        let chips: [(Bool, String)] = [
            (item.appHidden, "circle.slash"),
            (item.isFullscreen, "arrow.down.right.and.arrow.up.left"),
            (item.isMinimized, "minus.circle"),
        ]
        for (flag, symbol) in chips where flag {
            drawStateChip(symbol, corner: NSPoint(x: chipX, y: anchor.maxY - 24), dark: dark)
            chipX -= 22
        }

        // 标题条：应用图标 + "应用名 — 窗口标题"（纯图标样式不显示）
        if style != .appIcons {
        let iconSide = AppSettings.shared.iconSize.side
        let iconRect = CGRect(x: card.title.minX + 2, y: card.title.midY - iconSide / 2,
                              width: iconSide, height: iconSide)
        item.app.icon?.draw(in: iconRect)

        // 同应用多窗口角标：图标右上角显示窗口数
        let appKey = item.app.bundleIdentifier ?? item.appName
        let windowCount = appCounts[appKey] ?? 1
        let textX: CGFloat
        if windowCount > 1 {
            let d = CGFloat(13)
            let b = CGRect(x: iconRect.maxX - d * 0.65, y: iconRect.maxY - d * 0.65, width: d, height: d)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: b).fill()
            let t = "\(windowCount)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let size = t.size(withAttributes: attrs)
            t.draw(at: NSPoint(x: b.midX - size.width / 2, y: b.midY - size.height / 2), withAttributes: attrs)
            textX = iconRect.maxX + 9
        } else {
            textX = iconRect.maxX + 6
        }

        let textRect = CGRect(x: textX, y: card.title.minY,
                              width: max(10, card.title.maxX - textX), height: card.title.height)
        let full = item.title.isEmpty ? item.appName : "\(item.appName) — \(item.title)"
        let ps = NSMutableParagraphStyle()
        ps.lineBreakMode = .byTruncatingMiddle
        full.draw(in: textRect, withAttributes: [
            .font: NSFont.systemFont(ofSize: AppSettings.shared.titleFontSize.size, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: ps,
        ])
        }

        // 选中描边
        if selected {
            let ring = NSBezierPath(roundedRect: card.frame.insetBy(dx: 1.5, dy: 1.5), xRadius: 11, yRadius: 11)
            ring.lineWidth = 3
            NSColor.controlAccentColor.setStroke()
            ring.stroke()
        }

        // 数字直选角标（1–9）
        if index < 9 {
            let b = CGRect(x: card.frame.maxX - 24, y: card.frame.maxY - 24, width: 17, height: 17)
            NSColor.controlAccentColor.withAlphaComponent(0.92).setFill()
            NSBezierPath(ovalIn: b).fill()
            let d = "\(index + 1)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let size = d.size(withAttributes: attrs)
            d.draw(at: NSPoint(x: b.midX - size.width / 2, y: b.midY - size.height / 2), withAttributes: attrs)
        }

        ctx.restoreGState()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = cards.firstIndex(where: { $0.frame.contains(p) }) {
            onPick?(i)
        }
    }

    // MARK: - 悬停选中（对齐 AltTab：鼠标划过即选中该卡片）

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !trackingInstalled, window != nil else { return }
        trackingInstalled = true
        // .inVisibleRect 让跟踪区域随视图尺寸自动变化；.activeAlways 允许 App 未激活时也收到移动事件
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = cards.firstIndex(where: { $0.frame.contains(p) }), i != selection else { return }
        selection = i
        needsDisplay = true
    }
}

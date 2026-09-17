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
    /// 递增计数：面板关闭后用于丢弃仍在路上的异步截图回调
    var generation = 0
    var onPick: ((Int) -> Void)?

    private let inset: CGFloat = 16
    private let spacing: CGFloat = 12
    private let titleHeight: CGFloat = 30
    private let cardPadding: CGFloat = 8

    @discardableResult
    func update(items: [WindowItem], selection: Int, thumbSize: NSSize, maxWidth: CGFloat) -> NSSize {
        self.items = items
        self.selection = min(max(0, selection), max(0, items.count - 1))
        generation += 1
        cards.removeAll()

        let cardW = thumbSize.width + cardPadding * 2
        let cardH = thumbSize.height + titleHeight + cardPadding * 2
        let availW = max(cardW, maxWidth - inset * 2)
        let per = max(1, Int((availW + spacing) / (cardW + spacing)))
        perRow = per
        let count = items.count
        let cols = min(count, per)
        let rows = Int(ceil(Double(max(count, 1)) / Double(per)))
        let gridW = CGFloat(cols) * cardW + CGFloat(cols - 1) * spacing
        let gridH = CGFloat(rows) * cardH + CGFloat(rows - 1) * spacing
        let size = NSSize(width: gridW + inset * 2, height: gridH + inset * 2)

        for i in 0..<count {
            let r = i / per
            let c = i % per
            let colsInRow = min(per, count - r * per)
            let rowW = CGFloat(colsInRow) * cardW + CGFloat(colsInRow - 1) * spacing
            let x0 = inset + (gridW - rowW) / 2
            // 非翻转坐标系：第 0 行在最上方
            let y = size.height - inset - CGFloat(r + 1) * cardH - CGFloat(r) * spacing
            let frame = CGRect(x: x0 + CGFloat(c) * (cardW + spacing), y: y, width: cardW, height: cardH)
            let thumb = CGRect(x: frame.minX + cardPadding,
                               y: frame.maxY - cardPadding - thumbSize.height,
                               width: thumbSize.width, height: thumbSize.height)
            let title = CGRect(x: frame.minX + cardPadding,
                               y: frame.minY + cardPadding,
                               width: frame.width - cardPadding * 2, height: titleHeight)
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
        for (i, item) in items.enumerated() {
            guard i < cards.count else { break }
            drawCard(item, card: cards[i], index: i, selected: i == selection, dark: dark, ctx: ctx)
        }
    }

    private func drawCard(_ item: WindowItem, card: Card, index: Int, selected: Bool, dark: Bool, ctx: CGContext) {
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

        // 缩略图区域（圆角裁剪）
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

        // 标题条：应用图标 + "应用名 — 窗口标题"
        let iconRect = CGRect(x: card.title.minX + 2, y: card.title.midY - 9, width: 18, height: 18)
        item.app.icon?.draw(in: iconRect)
        let textX = iconRect.maxX + 6
        let textRect = CGRect(x: textX, y: card.title.minY,
                              width: max(10, card.title.maxX - textX), height: card.title.height)
        let full = item.title.isEmpty ? item.appName : "\(item.appName) — \(item.title)"
        let ps = NSMutableParagraphStyle()
        ps.lineBreakMode = .byTruncatingMiddle
        full.draw(in: textRect, withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: ps,
        ])

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
}

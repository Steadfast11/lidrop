import AppKit

/// Received items sit on the desktop like Finder icons: a column at the top right, newest first, thumbnail and name.
/// Each item is its own tiny non-activating panel, so everything outside one stays click-through.
/// Drag one out (copy), click = reveal in Finder, × on hover = dismiss, auto-fades after 60 s.
final class Shelf {
    var cards: [ShelfCard] = []

    /// The new item appears after `delay`, when the flying tile reaches it. Returns where to fly, in screen coordinates.
    @discardableResult
    func add(urls: [URL], image: NSImage?, delay: Double, onOpen: (() -> Void)? = nil) -> (center: CGPoint, size: CGFloat)? {
        guard !urls.isEmpty else { return nil }
        let card = ShelfCard(urls: urls, image: image) { [weak self] card in
            self?.cards.removeAll { $0 === card }
            self?.layout(animated: true)
        }
        card.onOpen = onOpen
        cards.append(card)
        layout(animated: true)
        card.show(after: delay)
        return (card.thumbCenter, ShelfCard.thumb)
    }

    /// Newest on top; the older ones slide down a place.
    func layout(animated: Bool) {
        guard let f = NSScreen.main?.visibleFrame else { return }
        for (i, c) in cards.enumerated() {
            let k = CGFloat(cards.count - 1 - i)   // 0 = newest
            c.place(topRight: NSPoint(x: f.maxX - 8, y: f.maxY - 10 - k * ShelfCard.cellH), animated: animated && k > 0)
            c.panel.orderFrontRegardless()
        }
    }
}

final class ShelfCard: NSObject, NSDraggingSource {
    let urls: [URL]
    let panel: NSPanel
    let view: CardView
    var fadeTimer: Timer?
    var onOpen: (() -> Void)?   // set while a video is still arriving: click plays it
    let onClose: (ShelfCard) -> Void
    static let cellW: CGFloat = 112, cellH: CGFloat = 112, thumb: CGFloat = 62

    init(urls: [URL], image: NSImage?, onClose: @escaping (ShelfCard) -> Void) {
        self.urls = urls; self.onClose = onClose
        view = CardView(frame: NSRect(x: 0, y: 0, width: ShelfCard.cellW, height: ShelfCard.cellH))
        panel = NSPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        view.card = self
        view.image = image ?? NSWorkspace.shared.icon(forFile: urls[0].path)
        view.name = urls.count > 1 ? "\(urls.count) files" : urls[0].lastPathComponent
        view.count = urls.count
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar            // above normal windows, below the effects overlay
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = view
        panel.alphaValue = 0
    }

    var thumbCenter: CGPoint {
        CGPoint(x: panel.frame.minX + view.tileRect.midX, y: panel.frame.minY + view.tileRect.midY)
    }

    func place(topRight p: NSPoint, animated: Bool) {
        let r = NSRect(x: p.x - ShelfCard.cellW, y: p.y - ShelfCard.cellH, width: ShelfCard.cellW, height: ShelfCard.cellH)
        if animated { NSAnimationContext.runAnimationGroup { $0.duration = 0.3; panel.animator().setFrame(r, display: true) } }
        else { panel.setFrame(r, display: true) }
    }

    /// Appears as the flying tile arrives, then stays (auto-fade after 60 s).
    func show(after delay: Double) {
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.panel.alphaValue = 1
            if self.onOpen == nil { self.startFade() }
        }
    }

    private func startFade() {
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in self?.dismiss(duration: 0.6) }
    }

    func setProgress(_ f: Double) { view.progress = f; view.needsDisplay = true }

    /// The whole file is here: from now on the card behaves like any other.
    func finished() {
        onOpen = nil
        view.progress = nil
        view.needsDisplay = true
        startFade()
    }

    func dismiss(duration: Double = 0.15) {
        fadeTimer?.invalidate()
        NSAnimationContext.runAnimationGroup({ $0.duration = duration; self.panel.animator().alphaValue = 0 }) { [self] in
            panel.orderOut(nil)
            onClose(self)
        }
    }

    func reveal() { if let onOpen { onOpen() } else { NSWorkspace.shared.activateFileViewerSelecting(urls) } }

    // MARK: NSDraggingSource (copy semantics)
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    func beginDrag(with event: NSEvent) {
        guard onOpen == nil else { return }   // the file is not complete yet
        let items = urls.enumerated().map { (i, u) -> NSDraggingItem in
            let it = NSDraggingItem(pasteboardWriter: u as NSURL)
            let r = view.tileRect.offsetBy(dx: CGFloat(i) * 4, dy: -CGFloat(i) * 4)
            it.setDraggingFrame(r, contents: i == 0 ? view.image : NSWorkspace.shared.icon(forFile: u.path))
            return it
        }
        view.beginDraggingSession(with: items, event: event, source: self)
    }
}

final class CardView: NSView {
    weak var card: ShelfCard?
    var image: NSImage?
    var name = ""
    var count = 1
    var progress: Double?
    var hover = false
    var downAt: NSPoint?
    var dragged = false

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }

    /// The thumbnail keeps the file's shape, centred in the top of the cell.
    var tileRect: NSRect {
        let s = image?.size ?? NSSize(width: 1, height: 1), side = ShelfCard.thumb
        let k = min(side / max(s.width, 1), side / max(s.height, 1))
        let w = s.width * k, h = s.height * k
        return NSRect(x: (bounds.width - w) / 2, y: bounds.height - 6 - side + (side - h) / 2, width: w, height: h)
    }
    var closeRect: NSRect { NSRect(x: tileRect.maxX - 11, y: tileRect.maxY - 11, width: 20, height: 20) }

    override func draw(_ dirty: NSRect) {
        let r = tileRect
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(0.4); sh.shadowBlurRadius = 5; sh.shadowOffset = NSSize(width: 0, height: -2)
        sh.set()
        NSColor(white: 0.95, alpha: 1).setFill()
        NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).addClip()
        image?.draw(in: r)
        if let progress {   // still arriving
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSRect(x: r.minX, y: r.minY, width: r.width, height: 4).fill()
            NSColor.white.setFill()
            NSRect(x: r.minX, y: r.minY, width: r.width * progress, height: 4).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingMiddle
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.75); shadow.shadowBlurRadius = 2; shadow.shadowOffset = NSSize(width: 0, height: -1)
        NSAttributedString(string: name, attributes: [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.white, .paragraphStyle: style, .shadow: shadow])
            .draw(with: NSRect(x: 4, y: 4, width: bounds.width - 8, height: 32), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if count > 1 {   // count badge
            let d: CGFloat = 20
            let b = NSRect(x: r.maxX - d * 0.7, y: r.minY - d * 0.3, width: d, height: d)
            NSColor.systemRed.setFill(); NSBezierPath(ovalIn: b).fill()
            let s = NSAttributedString(string: "\(count)", attributes: [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.white])
            let sz = s.size()
            s.draw(at: NSPoint(x: b.midX - sz.width / 2, y: b.midY - sz.height / 2))
        }
        if hover {   // × to dismiss
            let c = closeRect
            NSColor(white: 0.1, alpha: 0.85).setFill(); NSBezierPath(ovalIn: c).fill()
            NSColor.white.setStroke()
            let x = NSBezierPath(); x.lineWidth = 2
            x.move(to: NSPoint(x: c.minX + 6, y: c.minY + 6)); x.line(to: NSPoint(x: c.maxX - 6, y: c.maxY - 6))
            x.move(to: NSPoint(x: c.minX + 6, y: c.maxY - 6)); x.line(to: NSPoint(x: c.maxX - 6, y: c.minY + 6))
            x.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        downAt = convert(event.locationInWindow, from: nil)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let d = downAt, !dragged else { return }
        let p = convert(event.locationInWindow, from: nil)
        if hypot(p.x - d.x, p.y - d.y) > 4 {
            dragged = true
            card?.beginDrag(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { downAt = nil }
        guard !dragged, let d = downAt else { return }
        if hover && closeRect.contains(d) { card?.dismiss() } else { card?.reveal() }
    }
}

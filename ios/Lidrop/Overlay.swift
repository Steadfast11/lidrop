import SwiftUI
import UIKit

/// Rounded tile with shadow, drawn as a small stack with a count badge when it stands for several files.
/// Used for the picked-up tile and the Mac→phone tile.
final class TileView: UIView {
    private let card = UIView()
    private let box = UIView()
    private let img = UIImageView()
    private let label = UILabel()
    private let back = [UIView(), UIView()]
    private let fan = [UIImageView(), UIImageView()]   // a group: the next files, fanned out behind the first
    private let badge = UILabel()
    let bar = UIProgressView(progressViewStyle: .bar)

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: TILE, height: TILE))
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.45
        card.layer.shadowRadius = 14
        card.layer.shadowOffset = CGSize(width: 0, height: 6)
        box.backgroundColor = UIColor(red: 0.227, green: 0.247, blue: 0.278, alpha: 1)
        box.layer.cornerRadius = 16
        box.clipsToBounds = true
        img.contentMode = .scaleAspectFill
        img.clipsToBounds = true
        label.text = "FILE"
        label.textColor = .white
        label.textAlignment = .center
        for (i, b) in back.enumerated() {
            b.backgroundColor = UIColor(red: 0.29, green: 0.314, blue: 0.357, alpha: 0.7 - 0.2 * CGFloat(i))
            b.layer.cornerRadius = 16
            insertSubview(b, at: 0)
        }
        badge.backgroundColor = UIColor(red: 0.30, green: 0.64, blue: 1, alpha: 1)
        badge.textColor = .black
        badge.font = .systemFont(ofSize: 12, weight: .medium)
        badge.textAlignment = .center
        badge.layer.cornerRadius = 10
        badge.clipsToBounds = true
        bar.isHidden = true
        for v in fan {
            v.contentMode = .scaleAspectFill
            v.clipsToBounds = true
            v.layer.cornerRadius = 16
            v.isHidden = true
            addSubview(v)
        }
        addSubview(card)
        card.addSubview(box)
        box.addSubview(label); box.addSubview(img); box.addSubview(bar)
        addSubview(badge)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The selected tiles spread out behind the one in the hand.
    func setFan(_ images: [UIImage]) {
        for (i, v) in fan.enumerated() where i < images.count {
            let dir: CGFloat = i == 0 ? 1 : -1
            v.image = images[i]
            v.transform = .identity
            v.frame = bounds.insetBy(dx: TILE * 0.03, dy: TILE * 0.03)
            v.alpha = 0
            v.isHidden = false
            UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.62, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
                v.alpha = 1
                v.transform = CGAffineTransform(translationX: 16 * dir, y: 0).rotated(by: 8 * dir * .pi / 180)
            }
        }
    }

    /// `keepShape`: the tile takes the file's own shape inside the square, as the picked-up tile does on Android.
    func set(_ image: UIImage?, count: Int = 1, keepShape: Bool = false, stack: Bool = true) {
        for v in fan { v.isHidden = true; v.image = nil }
        img.image = image
        img.isHidden = image == nil
        bar.isHidden = true
        bar.progress = 0
        var r = bounds
        if keepShape, let s = image?.size, s.width > 0, s.height > 0 {
            let w = s.width >= s.height ? TILE : TILE * s.width / s.height
            let h = s.height >= s.width ? TILE : TILE * s.height / s.width
            r = CGRect(x: (TILE - w) / 2, y: (TILE - h) / 2, width: w, height: h)
        }
        card.frame = r
        box.frame = card.bounds
        img.frame = box.bounds
        label.frame = box.bounds
        bar.frame = CGRect(x: 14, y: box.bounds.height - 18, width: box.bounds.width - 28, height: 4)
        card.layer.shadowPath = UIBezierPath(roundedRect: card.bounds, cornerRadius: 16).cgPath
        for (i, b) in back.enumerated() {
            b.frame = r.offsetBy(dx: 6 * CGFloat(2 - i), dy: 6 * CGFloat(2 - i))
            b.isHidden = count <= 1 || !stack
        }
        badge.isHidden = count <= 1
        badge.text = "\(count)"
        let bw = max(24, CGFloat("\(count)".count) * 8 + 14)
        badge.frame = CGRect(x: r.maxX - bw - 6, y: r.minY + 6, width: bw, height: 20)
    }
}

/// Full-screen, touch-transparent UIKit layer that draws the light, the dragged tile and the Mac→phone tile.
/// Driven imperatively from one display link (no SwiftUI invalidation per frame).
final class OverlayView: UIView {
    private let senderLight = FxView()
    private let receiverLight = FxView()
    let dragTile = TileView()
    let inTile = TileView()
    private weak var drag: DragController?
    private weak var receiver: Receiver?
    private(set) var inSide = Side.left
    private(set) var inAlong: CGFloat = 0.5
    private var inDepth: CGFloat = 0
    private var inActive = false
    private var tween: (from: CGFloat, to: CGFloat, t0: CFTimeInterval, dur: CFTimeInterval, done: (() -> Void)?)?
    private var link: CADisplayLink?

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        senderLight.isHidden = true
        receiverLight.isHidden = true
        addSubview(senderLight); addSubview(receiverLight); addSubview(inTile); addSubview(dragTile)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        senderLight.frame = bounds
        receiverLight.frame = bounds
    }

    func attach(drag: DragController, receiver: Receiver?) {
        self.drag = drag
        self.receiver = receiver
        drag.light.onRun = { [weak self] in self?.run() }
        receiver?.fx.onRun = { [weak self] in self?.run() }
    }

    private func run() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick() {
        FxClock.now = FxClock.wall()
        let pt = Float(pointsPerMM(nativeScale: window?.screen.nativeScale ?? 3))
        let w = Float(bounds.width), h = Float(bounds.height)
        func render(_ fx: FxState?, _ v: FxView) {
            if let fx, fx.running, let u = lightFrame(fx, w: w, h: h, ptPerMm: pt) { v.isHidden = false; v.draw(light: u) }
            else { v.isHidden = true }
        }
        render(drag?.light, senderLight)
        render(receiver?.fx, receiverLight)
        layoutDrag()
        if let t = tween {
            let f = min((CACurrentMediaTime() - t.t0) / t.dur, 1)
            inDepth = t.from + (t.to - t.from) * CGFloat(1 - (1 - f) * (1 - f))
            if f >= 1 { tween = nil; t.done?() }
        }
        layoutIncoming()
        let busy = drag?.light.running == true || receiver?.fx.running == true || drag?.active != nil || drag?.linger != nil || inActive
        if !busy { link?.invalidate(); link = nil }
    }

    // MARK: phone → Mac tile
    func beginDrag(_ a: ActiveDrag) {
        dragTile.set(a.thumb, count: a.items.count, keepShape: a.items.count == 1, stack: false)
        dragTile.isHidden = false
        dragTile.alpha = 1
        // it flies from under the finger to the middle of the screen, where it waits to be thrown
        dragTile.transform = CGAffineTransform(translationX: a.f0.x - bounds.midX, y: a.f0.y - bounds.midY).scaledBy(x: a.startScale, y: a.startScale)
        UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.72, initialSpringVelocity: 0, options: [.allowUserInteraction]) { self.dragTile.transform = .identity }
        run()
    }

    func setDragImage(_ image: UIImage) {
        if let a = drag?.active, a.items.count == 1 { dragTile.set(image, keepShape: true) }
    }

    private func layoutDrag() {
        guard let d = drag?.active ?? drag?.linger, let fx = drag?.light else { return }
        let th = CGFloat(fx.thrust(0)) * TILE   // leaves through the seam as the wave arrives
        let dx: CGFloat = fx.side == .left ? -th : fx.side == .right ? th : 0
        let dy: CGFloat = fx.side == .top ? -th : fx.side == .bottom ? th : 0
        dragTile.center = CGPoint(x: d.x - dx + TILE / 2, y: d.y - dy + TILE / 2)
        dragTile.alpha = CGFloat(fx.tileAlpha())
    }

    func endDrag() { dragTile.isHidden = true }

    // MARK: Mac → phone tile
    func showIncoming(_ image: UIImage?, count: Int, side: Side) {
        inSide = side; inDepth = 0; inAlong = 0.5; tween = nil; inActive = true
        inTile.set(image, count: count)
        inTile.alpha = 1
        inTile.isHidden = false
        layoutIncoming()
        run()
    }

    func updateIncoming(depth: CGFloat, along: CGFloat) { tween = nil; inDepth = depth; inAlong = along }

    func animateIncoming(depth: CGFloat, duration: TimeInterval, done: (() -> Void)? = nil) {
        tween = (inDepth, depth, CACurrentMediaTime(), duration, done)
        run()
    }

    func setIncomingProgress(_ p: Float) { inTile.bar.isHidden = false; inTile.bar.progress = p }

    func fadeIncoming() {
        UIView.animate(withDuration: 0.25, delay: 0.4, options: []) { self.inTile.alpha = 0 } completion: { _ in self.hideIncoming() }
    }

    func hideIncoming() {
        tween = nil; inActive = false
        inTile.isHidden = true
        inTile.alpha = 1
        inTile.transform = .identity
    }

    private func layoutIncoming() {
        guard inActive else { return }
        let w = TILE, sw = bounds.width, sh = bounds.height, depth = inDepth * w
        var c: CGPoint
        switch inSide {
        case .left: c = CGPoint(x: -w / 2 + depth, y: inAlong * sh)
        case .right: c = CGPoint(x: sw + w / 2 - depth, y: inAlong * sh)
        case .top: c = CGPoint(x: inAlong * sw, y: -w / 2 + depth)
        case .bottom: c = CGPoint(x: inAlong * sw, y: sh + w / 2 - depth)
        }
        if let fx = receiver?.fx {
            let inward = inSide.horizontal ? sw : sh
            let th = CGFloat(fx.thrust(Float(0.42 * inward / w))) * w   // the wave carries it deep into the screen
            switch inSide {
            case .left: c.x += th
            case .right: c.x -= th
            case .top: c.y += th
            case .bottom: c.y -= th
            }
            let lean = -4 * CGFloat(min(max(fx.thrust(1), 0), 1)) * .pi / 180
            inTile.transform = CGAffineTransform(rotationAngle: lean)
        }
        inTile.center = c
    }
}

struct OverlayHost: UIViewRepresentable {
    let view: OverlayView
    func makeUIView(context: Context) -> OverlayView { view }
    func updateUIView(_ v: OverlayView, context: Context) {}
}

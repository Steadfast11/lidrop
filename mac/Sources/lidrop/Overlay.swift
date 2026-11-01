import AppKit

var vSpan: CGFloat = 0.85, hSpan: CGFloat = 0.30   // phone screen as a share of the Mac screen (set per drag)
let debugFX = ProcessInfo.processInfo.environment["LIDROP_DEBUG_FX"] != nil
var tileSize: CGFloat = 96  // set per drag from the phone's tile_dp (DEMO-CONST: 1 dp ≈ 0.91 pt on a 13" MacBook Air)

/// Full-screen, click-through panel on the main screen; draws one tile and
/// eases it toward the target the phone last reported.
final class OverlayController: NSObject {
    enum Mode { case hidden, dragging, settled, retracting, landing, macGlow, macBurst, pairing }

    var panel: NSPanel?
    let tile = NSView(frame: NSRect(x: 0, y: 0, width: tileSize, height: tileSize))
    let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: tileSize, height: tileSize))
    let pic = CALayer()   // aspect-fill picture layer (center-crop like the phone, never stretched)
    var link: CADisplayLink?
    var lastTick = CACurrentMediaTime()

    var mode = Mode.hidden
    var curOver = 0.0, curAlong = 0.5
    var tgtOver = 0.0, tgtAlong = 0.5
    var scale: CGFloat = 1, alpha: CGFloat = 1
    var landT = 0.0
    var edge = "right"   // Mac entry edge currently rendered
    var wantEdge = "right", wantOver = 0.0
    var count = 1
    let fx = LightFX()
    let glass = GlassFX()
    var pairP = 0.0, pairLink = Spring()    // connect ceremony: the hold, and the lens that follows it
    var pairT = -1.0, pairLast = 0.0        // seconds since the wave started; when the phone last said it holds
    var charge = Spring()   // light charge p (0…1), spring-smoothed
    var pc: Double { charge.x }
    var fxT = 0.0           // seconds since commit
    var clock = 0.0
    var ghost = false       // Mac → phone: glow/burst only, no tile
    var lastCenter = CGPoint.zero
    var fxOut = -1.0
    var energy = Spring(), lastOver = 0.0, lastAlong = 0.5
    var armedAge = -1.0     // seconds since the drag crossed the commit line
    var thrust = 0.0        // tile lands past its resting place, in tile sizes
    var travel = Spring(), flying = false   // after release: one unbroken move from where the tile is to where it lands
    var overV = 0.0, alongV = 0.0           // drag speed at the moment of release, in tiles and screen lengths per second
    var tilt = 0.0          // tile leans a little in flight (radians)
    var imageAspect: CGFloat = 1
    var flyP = 0.0          // last moment: it shrinks away where it landed
    let blur = NSVisualEffectView()   // the wallpaper really softens under the light
    let blurMask = CAGradientLayer()
    var previewT = -1.0     // seconds into a "Preview light" run, -1 = none
    var tickGaps: [Double] = [], tickCosts: [Double] = []   // LIDROP_DEBUG_FX only

    func tileCenter(_ w: CGFloat, _ h: CGFloat) -> CGPoint { lastCenter }
    let back1 = CALayer(), back2 = CALayer(), badgeBG = CALayer(), badgeText = CATextLayer()

    override init() {
        super.init()
        fx.collect = debugFX
        tile.wantsLayer = true
        tile.layer?.shadowColor = NSColor.black.cgColor
        tile.layer?.shadowOpacity = 0.4
        tile.layer?.shadowRadius = 12
        tile.layer?.shadowOffset = CGSize(width: 0, height: -4)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 20
        imageView.layer?.cornerCurve = .continuous
        imageView.layer?.masksToBounds = true
        imageView.layer?.backgroundColor = NSColor.gray.cgColor
        pic.contentsGravity = .resizeAspectFill
        pic.masksToBounds = true
        pic.contentsScale = 2
        pic.magnificationFilter = .trilinear
        pic.minificationFilter = .trilinear
        imageView.layer?.addSublayer(pic)
        tile.addSubview(imageView)
        for (i, l) in [back1, back2].enumerated() {   // stack look for multi-file drags (behind the picture)
            l.backgroundColor = NSColor(white: i == 0 ? 0.92 : 0.8, alpha: 1).cgColor
            l.borderColor = NSColor(white: 0.55, alpha: 0.6).cgColor
            l.borderWidth = 1
            l.isHidden = true
            tile.layer?.insertSublayer(l, at: 0)
        }
        badgeBG.backgroundColor = NSColor.systemRed.cgColor
        badgeText.alignmentMode = .center
        badgeText.foregroundColor = NSColor.white.cgColor
        badgeText.contentsScale = 2
        badgeText.font = NSFont.boldSystemFont(ofSize: 15)
        badgeText.fontSize = 15
        badgeBG.addSublayer(badgeText)
        badgeBG.isHidden = true
        badgeBG.zPosition = 10
        tile.layer?.addSublayer(badgeBG)
    }

    func ensurePanel() {
        guard let screen = NSScreen.main else { return }
        if panel == nil {
            let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.level = .screenSaver
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.isReleasedWhenClosed = false
            let v = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            v.wantsLayer = true
            v.addSubview(tile)
            tile.layer?.zPosition = 2
            blur.frame = v.bounds
            blur.autoresizingMask = [.width, .height]
            blur.blendingMode = .behindWindow
            blur.material = .fullScreenUI
            blur.state = .active
            blur.wantsLayer = true
            blur.isHidden = true
            v.addSubview(blur, positioned: .below, relativeTo: tile)
            blur.layer?.zPosition = -20
            blurMask.type = .radial
            blurMask.colors = [NSColor.white.cgColor, NSColor.white.cgColor, NSColor.clear.cgColor]
            blurMask.locations = [0, 0.72, 1]
            blur.layer?.mask = blurMask
            fx.install(in: v.layer!)
            glass.install(in: v.layer!)
            p.contentView = v
            panel = p
        }
        panel?.setFrame(screen.frame, display: false)
        panel?.contentView?.frame = NSRect(origin: .zero, size: screen.frame.size)
    }

    /// Physical size (mm) of the main display, so phone and Mac tiles can match in real centimetres.
    func mainScreenMm() -> (w: Double, h: Double)? {
        guard let s = NSScreen.main,
              let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let mm = CGDisplayScreenSize(CGDirectDisplayID(n.uint32Value))
        return mm.width > 0 && mm.height > 0 ? (Double(mm.width), Double(mm.height)) : nil
    }

    func dragStart(image: NSImage?, tileDp: Double, tileMm: Double?, phoneMm: (w: Double, h: Double)?, count: Int = 1) {
        self.count = count
        if let mac = mainScreenMm(), let screen = NSScreen.main {
            let mmPerPt = mac.w / Double(screen.frame.width)
            if let t = tileMm, t > 5 { tileSize = CGFloat(min(max(t / mmPerPt, 48), 500)) }   // same physical size
            else { tileSize = CGFloat(min(max(tileDp, 48), 400) * 0.91) }
            if let p = phoneMm, p.w > 20, p.h > 20 {   // phone screen as a share of the Mac screen (physical)
                vSpan = CGFloat(min(max(p.h / mac.h, 0.2), 1.0))
                hSpan = CGFloat(min(max(p.w / mac.w, 0.1), 1.0))
            }
        } else {
            tileSize = CGFloat(min(max(tileDp, 48), 400) * 0.91)
        }
        imageView.layer?.cornerRadius = tileSize * 0.09
        imageAspect = image.map { $0.size.height > 0 ? $0.size.width / $0.size.height : 1 } ?? 1
        var r = CGRect(origin: .zero, size: image?.size ?? .zero)
        pic.contents = image?.cgImage(forProposedRect: &r, context: nil, hints: nil)   // filled, not stretched
        ensurePanel()
        mode = .dragging
        curOver = 0; tgtOver = 0; wantOver = 0
        scale = 1; alpha = 1
        resetFX(ghost: false)
        render()
        panel?.orderFrontRegardless()
        startTimer()
    }

    func dragMove(phoneEdge: String, overhang: Double, along: Double) {
        guard mode == .dragging else { return }
        let opposite = ["left": "right", "right": "left", "top": "bottom", "bottom": "top"]
        wantEdge = opposite[phoneEdge] ?? "right"
        wantOver = min(max(overhang, 0), 1)
        tgtAlong = min(max(along, 0), 1)
        if curOver < 0.003 { edge = wantEdge }
        if wantOver > 0 { UserDefaults.standard.set(wantEdge, forKey: "learnedEdge") }
    }

    func resetFX(ghost g: Bool) {
        ghost = g; charge = Spring(); fxT = 0
        energy = Spring(); armedAge = -1; thrust = 0; tilt = 0; flyP = 0; flying = false; overV = 0; alongV = 0
        fx.sender = g
        fx.strength = g ? 0.5 : 1   // Mac → phone: this is the sending screen, the phone gets the strong light
        fx.start()
    }

    func settle() { mode = .settled; tgtOver = 1; fxT = 0 }
    func retract() { mode = .retracting; tgtOver = 0; thrust = 0; tilt = 0; flying = false }

    /// Mac → phone: glow at the edge the cursor is approaching (no tile). `over` = 0 at zone start, 1 on the edge.
    func macGlow(edge e: String, overhang: Double, along: Double) {
        if mode != .macGlow {
            ensurePanel()
            mode = .macGlow
            curOver = 0; scale = 1; alpha = 1
            resetFX(ghost: true)
            panel?.orderFrontRegardless()
            startTimer()
        }
        edge = e; wantEdge = e
        tgtOver = min(max(overhang, 0), 1)
        tgtAlong = min(max(along, 0), 1)
    }

    /// Mac → phone drag ended: commit = wrap + burst at the edge, otherwise a 200 ms fade.
    func macEnd(commit: Bool) {
        guard mode == .macGlow else { return }
        if commit { mode = .macBurst; tgtOver = 1; fxT = 0 }
        else { mode = .retracting; tgtOver = 0 }
    }
    /// Connect ceremony: while the phone holds, a lens of liquid glass swells at the seam. Only the first burst counts:
    /// a hold still on its way when the wave has started must not begin another one.
    func pair(hold p: Double) {
        guard mode == .pairing ? pairT < 0 : mode == .hidden else { return }
        if mode != .pairing {
            ensurePanel()
            mode = .pairing
            pairLink = Spring(); pairT = -1
            panel?.orderFrontRegardless()
            startTimer()
        }
        pairP = min(max(p, 0), 1)
        pairLast = CACurrentMediaTime()
    }

    func pairBurst() { if mode == .pairing && pairT < 0 { pairT = 0 } }

    func pairCancel() { pairLast = 0 }

    private func pairTick(_ now: Double, _ dt: Double) {
        guard let v = panel?.contentView, let mm = mainScreenMm() else { hide(); return }
        let held = now - pairLast < 0.4 || pairT >= 0
        pairLink.step(to: held ? 1 : 0, w: 9, dt: dt)
        var men = pairLink.x * GlassFX.lensMm(pairP), front = -1.0, fade = 1.0
        if pairT >= 0 {
            pairT += dt
            front = GlassFX.frontMm(pairT, macW: mm.w)
            fade = 1 - LightFX.ss(0.45, 0.95, pairT)
            men *= exp(-pairT / 0.08)
            if pairT > 1 { hide(); return }
        } else if !held && pairLink.x < 0.01 { hide(); return }
        let w = v.bounds.width, h = v.bounds.height, mmPerPt = mm.w / Double(w)
        let side = UserDefaults.standard.string(forKey: "learnedEdge") ?? "right"
        let seam: CGPoint
        switch side {
        case "left": seam = CGPoint(x: 0, y: h / 2)
        case "top": seam = CGPoint(x: w / 2, y: 0)
        case "bottom": seam = CGPoint(x: w / 2, y: h)
        default: seam = CGPoint(x: w, y: h / 2)
        }
        glass.draw(w: w, h: h, seam: seam, mmPerPt: mmPerPt, men: men, front: front, fade: fade)
        // the desktop really frosts under the glass; the gradient mask is in layer coordinates, y up
        let frost = (front >= 0 ? front : men) / mmPerPt / 0.72
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blur.isHidden = false
        blurMask.frame = v.bounds
        blur.layer?.opacity = Float(front >= 0 ? fade * fade : pairLink.x)
        let c = CGPoint(x: seam.x / w, y: 1 - seam.y / h)
        blurMask.startPoint = c
        blurMask.endPoint = CGPoint(x: c.x + frost / w, y: c.y + frost / h)
        CATransaction.commit()
    }

    /// How long until the tile shrinks away; its desktop icon appears as it goes.
    var landingDelay: Double { max(0, LightFX.shrinkAt - fxT) }
    func land() { mode = .landing; tgtOver = 1; landT = 0 }
    func cancel() { if mode != .hidden { retract() } }

    /// Display-linked, so the tick follows the screen's own 60/120 Hz instead of beating against it.
    func startTimer() {
        guard link == nil, let v = panel?.contentView else { return }
        lastTick = CACurrentMediaTime()
        let l = v.displayLink(target: self, selector: #selector(linkTick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc func linkTick() {
        guard debugFX else { tick(); return }
        let a = CACurrentMediaTime()
        tickGaps.append((a - lastTick) * 1000)
        tick()
        tickCosts.append((CACurrentMediaTime() - a) * 1000)
    }

    func printStats() {
        func pct(_ v: [Double], _ q: Double) -> Double { v.isEmpty ? 0 : v.sorted()[min(Int(Double(v.count) * q), v.count - 1)] }
        let (gpu, skipped) = fx.stats.take()
        let late = tickGaps.filter { $0 > 1000.0 / Double(panel?.screen?.maximumFramesPerSecond ?? 60) * 1.5 }.count
        print(String(format: "light stats: look=%@ ticks=%d late=%d skipped=%d gap p50=%.1f p99=%.1f max=%.1f ms, main tick p50=%.2f p99=%.2f max=%.2f ms, gpu p50=%.2f p99=%.2f max=%.2f ms",
                     LightLook.currentName, tickGaps.count, late, skipped, pct(tickGaps, 0.5), pct(tickGaps, 0.99), tickGaps.max() ?? 0,
                     pct(tickCosts, 0.5), pct(tickCosts, 0.99), tickCosts.max() ?? 0, pct(gpu, 0.5), pct(gpu, 0.99), gpu.max() ?? 0))
        tickGaps = []; tickCosts = []
    }

    /// Debug: plays approach, hold and landing with no phone attached (menu item "Preview light"), on the learned edge.
    func preview() {
        guard mode == .hidden else { return }
        macGlow(edge: UserDefaults.standard.string(forKey: "learnedEdge") ?? "right", overhang: 0, along: 0.45)
        fx.strength = 1
        fx.sender = false
        previewT = 0
    }

    func hide() {
        mode = .hidden
        fx.stop()
        glass.hide()
        blur.isHidden = true
        link?.invalidate(); link = nil
        previewT = -1
        panel?.orderOut(nil)
        if debugFX { printStats() }
    }

    func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.1)
        lastTick = now
        if mode == .pairing { pairTick(now, dt); return }
        if previewT >= 0 {
            previewT += dt
            if mode == .macGlow {
                tgtOver = min(previewT / 1.6, 1)
                if previewT > 2.6 { macEnd(commit: true) }
            }
        }
        let k = 1 - exp(-dt * 70)   // light smoothing (~14ms) so the tile tracks the finger without trailing
        if mode == .dragging {
            if wantEdge != edge {   // edge changed mid-drag: slide out the old one first
                tgtOver = 0
                if curOver < 0.02 { edge = wantEdge; curOver = 0 }
            } else {
                tgtOver = wantOver
            }
            if curOver < 0.003 { curAlong = tgtAlong }
        }
        curOver += (tgtOver - curOver) * k
        curAlong += (tgtAlong - curAlong) * k
        // light v5: charge p follows g = smoothstep(0, 0.5, overhang) on a critically damped spring, 90 % in ~350 ms
        // up and ~450 ms down; commit: p jumps up fast and holds, then drains while the field dissolves in the shader
        let committed = mode == .settled || mode == .landing || mode == .macBurst
        if !committed {
            overV += ((curOver - lastOver) / max(dt, 0.001) - overV) * 0.35
            alongV += ((curAlong - lastAlong) / max(dt, 0.001) - alongV) * 0.35
        }
        let o = min(max(curOver, 0), 1)
        // the sender's light pours across: it peaks early and thins as the receiver's light takes over
        var g = fx.sender ? LightFX.ss(0, 0.25, o) * (1 - 0.55 * LightFX.ss(0.25, 1, o)) : LightFX.ss(0, 0.5, o)
        var w = 0.0
        if committed {
            fxT += dt
            g = fxT < 0.25 ? 1 : 0
            w = g > pc ? 30 : 8
            if !ghost, let v = panel?.contentView {   // the tile never stops: it carries its speed across the seam to its place
                let inward = edge == "left" || edge == "right" ? v.bounds.width : v.bounds.height
                if !flying {
                    flying = true
                    travel = Spring(x: curOver, v: min(max(overV, 0), 12))
                    tgtAlong = min(max(curAlong + alongV * 0.18, 0.08), 0.92)
                }
                travel.step(to: 1 + Double(0.42 * inward / tileSize), w: 9, dt: dt)
                thrust = travel.x - curOver
                tilt = -0.07 * (1 - exp(-fxT * 10))
            }
        } else {
            if mode == .retracting { g = 0 }
            w = g > pc ? 3.9 : 8.6
        }
        charge.step(to: g, w: w, dt: dt)
        let moved = (abs(curOver - lastOver) + abs(curAlong - lastAlong)) / max(dt, 0.001)
        lastOver = curOver; lastAlong = curAlong
        energy.step(to: min(moved * 0.35, 1), w: 6, dt: dt)
        let line = ghost ? 0.83 : 0.5
        if armedAge < 0 { if curOver >= line && !committed { armedAge = 0 } }
        else { armedAge += dt; if curOver < line - 0.08 { armedAge = -1 } }
        fx.energy = energy.x; fx.armedAge = armedAge
        clock += dt
        fxOut = committed ? fxT : -1
        switch mode {
        case .retracting:
            if curOver < 0.003 && pc < 0.01 { hide(); return }
        case .landing:
            landT += dt
            let wait = max(0, LightFX.shrinkAt - (fxT - landT))
            flyP = min(max((landT - wait) / 0.2, 0), 1)
            alpha = CGFloat(1 - LightFX.ss(0.5, 1, flyP))
            if landT >= wait + 0.2 && fxT > fx.look.dissolve && pc < 0.01 { hide(); return }
        case .macBurst:
            if fxT > fx.look.dissolve && pc < 0.01 { hide(); return }
        default: break
        }
        render()
    }

    func render() {
        guard let v = panel?.contentView else { return }
        let w = v.bounds.width, h = v.bounds.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tile.layer?.setAffineTransform(.identity)
        tile.frame.size = NSSize(width: tileSize, height: tileSize)
        // the tile keeps the file's own shape, fitted in the square the geometry uses
        let iw = imageAspect >= 1 ? tileSize : tileSize * imageAspect, ih = imageAspect >= 1 ? tileSize / imageAspect : tileSize
        imageView.frame = NSRect(x: (tileSize - iw) / 2, y: (tileSize - ih) / 2, width: iw, height: ih)
        let d = CGFloat(curOver + thrust) * tileSize
        // DEMO-CONST: the phone is roughly as tall as ~85% of the Mac screen (and ~30% as wide), centred next
        // to it, so the tile continues where it left the phone instead of spanning the whole Mac edge.
        let vertical = edge == "left" || edge == "right"
        let a = ghost ? CGFloat(curAlong) : 0.5 + (CGFloat(curAlong) - 0.5) * (vertical ? vSpan : hSpan)
        var x: CGFloat, ty: CGFloat
        switch edge {
        case "left", "right":
            x = edge == "right" ? w - d : d - tileSize
            ty = min(max(h - a * h - tileSize / 2, 8), h - tileSize - 8)
        default:
            x = min(max(a * w - tileSize / 2, 8), w - tileSize - 8)
            ty = edge == "top" ? h - d : d - tileSize
        }
        lastCenter = CGPoint(x: x + tileSize / 2, y: ty + tileSize / 2)
        let flyScale = 1 - 0.8 * CGFloat(LightFX.ss(0, 1, flyP))
        tile.frame.origin = NSPoint(x: x, y: ty)
        pic.frame = CGRect(x: 0, y: 0, width: iw, height: ih)
        let stacked = count > 1
        for (l, deg) in [(back1, 7.0), (back2, -6.0)] {
            l.isHidden = !stacked
            l.bounds = CGRect(x: 0, y: 0, width: tileSize, height: tileSize)
            l.position = CGPoint(x: tileSize / 2, y: tileSize / 2)
            l.cornerRadius = tileSize * 0.2
            l.transform = CATransform3DMakeRotation(CGFloat(deg) * .pi / 180, 0, 0, 1)
        }
        badgeBG.isHidden = !stacked
        if stacked {
            let d: CGFloat = max(26, tileSize * 0.3)
            // badge on the corner that is on screen first (the leading one)
            badgeBG.frame = CGRect(x: edge == "left" ? tileSize - d * 0.7 : -d * 0.3, y: tileSize - d * 0.7, width: d, height: d)
            badgeBG.cornerRadius = d / 2
            badgeText.string = "\(count)"
            badgeText.fontSize = d * 0.55
            badgeText.frame = CGRect(x: 0, y: (d - d * 0.55 * 1.2) / 2, width: d, height: d * 0.7)
        }
        let mid = tileSize / 2   // layers of views pivot at their corner: turn and scale about the middle
        var pose = CGAffineTransform(translationX: mid, y: mid).rotated(by: CGFloat(tilt) * (1 - CGFloat(flyP)))
        pose = pose.scaledBy(x: scale * flyScale, y: scale * flyScale).translatedBy(x: -mid, y: -mid)
        tile.layer?.setAffineTransform(pose)
        let entering = mode == .dragging ? 0.55 + 0.45 * LightFX.ss(0.1, 0.7, curOver) : 1   // arrives as a pale ghost, then solid
        tile.alphaValue = alpha * CGFloat(entering)
        tile.isHidden = ghost || curOver < 0.003
        fx.update(edge: edge, c: lastCenter, w: w, h: h, ts: tileSize, p: pc, fx: fxOut, t: clock)
        // the wallpaper softens outward from the seam, stays soft under the dome, then clears with it
                let soft = fxOut >= 0 ? 1 - LightFX.ss(0.45, 0.8, fxOut) : LightFX.ss(0.02, 0.5, pc)
        blur.isHidden = soft < 0.01
        if soft >= 0.01 {
            blurMask.frame = v.bounds
            blur.layer?.opacity = Float(soft)
            let c = CGPoint(x: lastCenter.x / w, y: lastCenter.y / h)
            let reach = 0.3 + 1.2 * soft
            blurMask.startPoint = c
            blurMask.endPoint = CGPoint(x: c.x + reach, y: c.y + reach * w / h)
        }
        CATransaction.commit()
    }
}

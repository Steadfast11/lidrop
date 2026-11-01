import Metal
import QuartzCore
import UIKit

/// Frame clock for the light effects (ms); same time base as `FxState`'s stamps.
enum FxClock {
    static var now: Int64 = 0
    static func wall() -> Int64 { Int64(CACurrentMediaTime() * 1000) }
}

/// One switchable look of the light field. Keep in step with `LightLook.all` in mac/Sources/lidrop/Effects.swift.
struct FxLook {
    let gain, sat, contrast, disp, warp, grain, dim, bloom, bloomR, pale, streak, flash, flashTau, flashHold, reach, dissolve: Float
}

enum Looks {
    private static let all: [String: FxLook] = [
        "A": FxLook(gain: 0.62, sat: 0.52, contrast: 1.4, disp: 0.7, warp: 0.8, grain: 1.2, dim: 0.18, bloom: 0.55, bloomR: 0.20, pale: 0.55, streak: 0, flash: 2.0, flashTau: 0.08, flashHold: 0.08, reach: 0.80, dissolve: 1.0),
        "B": FxLook(gain: 0.85, sat: 0.50, contrast: 1.5, disp: 1.0, warp: 1.0, grain: 1.6, dim: 0.62, bloom: 0.90, bloomR: 0.26, pale: 0.80, streak: 0.04, flash: 4.0, flashTau: 0.09, flashHold: 0.12, reach: 0.96, dissolve: 1.2),
        "C": FxLook(gain: 1.90, sat: 0.84, contrast: 1.9, disp: 1.5, warp: 1.2, grain: 2.2, dim: 0.76, bloom: 1.50, bloomR: 0.34, pale: 0.90, streak: 0.20, flash: 7.0, flashTau: 0.10, flashHold: 0.16, reach: 1.15, dissolve: 1.5),
    ]
    private(set) static var name = "B"
    private(set) static var cur = all["B"]!

    static func load() { pick(prefs.string(forKey: "look") ?? "B") }
    static func pick(_ n: String) { if let l = all[n] { cur = l; name = n } }
    static func save(_ n: String) { pick(n); prefs.set(name, forKey: "look") }
    static func next() { save(name == "A" ? "B" : name == "B" ? "C" : "A") }
}

/// The Mac's screen in mm (from `welcome`): the dome is one physical circle, so on the phone it overflows the screen.
enum Seam {
    static var macW: Float = 300
    static var macH: Float = 195
    static var macEdge: String?   // the Mac edge the phone sits at, from `welcome`
}

/// Critically damped spring, integrated exactly so any frame time is stable. ω = 3.9 / T settles 90 % of the way in T.
struct Spring {
    var x: Float = 0
    private var v: Float = 0
    mutating func reset() { x = 0; v = 0 }
    mutating func step(to: Float, w: Float, dt: Float) {
        let d = x - to, c = v + w * d, e = exp(-w * dt)
        x = to + (d + c * dt) * e
        v = (c - w * (d + c * dt)) * e
    }
}

/// Light-effects state for one drag (sender or receiver). Main thread only.
final class FxState {
    var overhang: Float = 0
    var along: Float = 0.5
    var side = Side.left
    var cx: Float = 0, cy: Float = 0   // tile centre, used by the burst
    var burstAt: Int64 = -1            // ms of the commit, -1 = none
    var cancelAt: Int64 = -1
    var running = false { didSet { if running { onRun?() } } }
    var onRun: (() -> Void)?
    var strong = true                  // receiving screen: full; sending phone: subtle accompaniment
    private var gen = 0
    var charge = Spring()
    var startT: Int64 = 0
    var seed: Float = 0
    var peak: Float = 0                // highest charge of this drag, read by the commit
    var energy = Spring()              // 0..1, how fast the drag is moving right now
    var lastO: Float = 0, lastA: Float = 0.5
    private var armed = false
    var armedAt: Int64 = -1            // ms the drag crossed the commit line; also drives the haptic
    var lastT: Int64 = 0

    @discardableResult
    func begin(_ s: Side) -> Int {
        side = s; overhang = 0; burstAt = -1; cancelAt = -1; charge.reset(); energy.reset(); peak = 0; armed = false; armedAt = -1
        FxClock.now = FxClock.wall(); lastT = FxClock.now; startT = lastT
        running = true
        gen += 1
        return gen
    }

    /// Sets the overhang and notices the commit line (0.5 for a phone drag, 0.83 for the Mac's edge zone).
    func over(_ v: Float, line: Float = 0.5) {
        overhang = v
        if !armed && v >= line && burstAt < 0 {
            armed = true; armedAt = FxClock.wall()
            UISelectionFeedbackGenerator().selectionChanged()
        } else if armed && v < line - 0.08 { armed = false; armedAt = -1 }
    }

    func commit() -> Int {
        burstAt = FxClock.wall()
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        gen += 1
        return gen
    }

    func cancel() -> Int { cancelAt = FxClock.wall(); gen += 1; return gen }
    func stillCurrent(_ g: Int) -> Bool { g == gen }

    /// How long the overlay must stay up after a commit for the field to finish dissolving.
    func endMs() -> Int { Int(Looks.cur.dissolve * 1000) + 150 }

    /// Commit, in tile sizes along the inward axis: the wave carries the receiver's tile deep in; the sender's leaves through the seam.
    func thrust(_ flight: Float) -> Float {
        if burstAt < 0 { return 0 }
        let since = Float(FxClock.now - burstAt) / 1000
        if !strong { return -1.2 * (1 - exp(-since / 0.05)) }   // keeps going through the seam, no pause
        return flight * (1 - exp(-since * 9) * (1 + since * 9))
    }

    /// The sender's tile is gone once the wave reaches the seam.
    func tileAlpha() -> Float {
        if burstAt < 0 { return 1 }
        return 1 - min(max(Float(FxClock.now - burstAt - 50) / 70, 0), 1)
    }

    /// Where the entering tile's centre is, for the receiver's burst (depth = visible fraction of the tile).
    func placeEntering(_ s: Side, _ depth: Float, _ alongF: Float, _ sw: Float, _ sh: Float, _ w: Float) {
        let d = depth * w
        switch s {
        case .left: cx = -w / 2 + d; cy = alongF * sh
        case .right: cx = sw + w / 2 - d; cy = alongF * sh
        case .top: cy = -w / 2 + d; cx = alongF * sw
        case .bottom: cy = sh + w / 2 - d; cx = alongF * sw
        }
    }
}

/// Same layout as `LightU` in Shaders.swift.
struct LightUniforms {
    var size = SIMD2<Float>(), origin = SIMD2<Float>()
    var side: Float = 0, along: Float = 0, k: Float = 0, head: Float = 0, wid: Float = 0, fan: Float = 0, pale: Float = 0, reach: Float = 0
    var bloom: Float = 0, bloomR: Float = 0, dimK: Float = 0, flash: Float = 0, front: Float = 0, ring: Float = 0, veil: Float = 0, tail: Float = 0
    var cool: Float = 0, sat: Float = 0, contrast: Float = 0, disp: Float = 0, warp: Float = 0, grain: Float = 0, streak: Float = 0, time: Float = 0, seed: Float = 0
}

/// Same layout as `PairU` in Shaders.swift.
struct PairUniforms {
    var size = SIMD2<Float>(), drop = SIMD2<Float>(), seam = SIMD2<Float>()
    var dropR: Float = 0, fill: Float = 0, jelly: Float = 0, time: Float = 0, front: Float = -1, fade: Float = 1, men: Float = 0
}

private let BEAT: Float = 0.09   // seconds of inhale after the commit
private let RISE: Float = 0.22   // the tile flies first: the dome only opens as it arrives

private func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float { let t = min(max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t) }
private func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

/**
 * Light effects v5 (docs/PROTOCOL.md), the same steps as `drawLight` in android/.../Light.kt. The charge `p` follows
 * proximity on a critically damped spring and only moves a dozen scalars; nil means nothing to draw this frame.
 * `w`/`h` are the screen in points, `ptPerMm` real points per millimetre.
 */
func lightFrame(_ fx: FxState, w: Float, h: Float, ptPerMm: Float) -> LightUniforms? {
    let now = FxClock.now
    let lk = Looks.cur

    // ---- charge p ----
    let dt = Float(min(max(now - fx.lastT, 0), 64)) / 1000; fx.lastT = now
    let since: Float = fx.burstAt >= 0 ? Float(now - fx.burstAt) / 1000 : -1
    var target: Float, rate: Float
    if fx.burstAt >= 0 { target = 1; rate = 30 }
    else if fx.cancelAt >= 0 { target = 0; rate = 8.6 }
    else {
        let o = fx.overhang   // the sender's light pours across: it peaks early and thins as the receiver's takes over
        target = fx.strong ? smooth(0, 0.5, o) : smooth(0, 0.25, o) * (1 - 0.55 * smooth(0.25, 1, o))
        rate = target > fx.charge.x ? 3.9 : 8.6
    }
    fx.charge.step(to: target, w: rate, dt: dt)
    let pv = fx.charge.x
    let moved = (abs(fx.overhang - fx.lastO) + abs(fx.along - fx.lastA)) / max(dt, 0.001)
    fx.lastO = fx.overhang; fx.lastA = fx.along
    fx.energy.step(to: min(moved * 0.35, 1), w: 6, dt: dt)
    let energy = fx.energy.x
    if pv > fx.peak { fx.peak = pv }
    let burst = since >= 0
    if pv < 0.004 && !burst { return nil }
    if since > lk.dissolve { return nil }

    let along0 = fx.along
    let tt = Float(now - fx.startT) / 1000 + 3
    let breath = sin(tt * 1.9)
    let q = burst ? max(fx.peak, 0.6) : pv
    let bigP = smooth(0, 1, q)
    var head = -0.05 + 0.74 * bigP + 0.25 * (along0 - 0.5)
    var wid = 0.95 - 0.42 * bigP
    var fan = lk.gain * smooth(0.05, 0.35, q) * (1 + 0.1 * breath) * (1 + 0.5 * energy)
    var pale = lk.pale * smooth(0.4, 1, q)
    var reach = 1.9 - 0.8 * bigP
    var bloom = lk.bloom * bigP * (0.4 + 0.6 * bigP) * (1 + 0.08 * sin(tt * 1.9 + 0.6))
    var bloomR = 0.2 + lk.bloomR * bigP
    var dim = lk.dim * smooth(0.08, 0.9, q)
    var flash: Float = 0, front: Float = 0, ring: Float = 0, veil: Float = 0, tail: Float = 0, cool: Float = 0
    var k: Float = fx.strong ? 1 : 0.55   // the sender only accompanies the drag
    if !burst && fx.armedAt >= 0 {        // crossing the commit line: one quiet pulse says "you can let go"
        let age = Float(now - fx.armedAt) / 1000
        let e = smooth(0, 0.04, age) * exp(-age / 0.42)
        bloom *= 1 + 0.9 * e
        ring = 0.35 * e
        front = 0.05 + 0.95 * (1 - exp(-age / 0.3))
    }
    if burst {   // both screens show the same dome, centred on the seam, at the same physical size
        let tEnd = lk.dissolve, hold = lk.flashHold
        let end = 1 - smooth(0.55 * tEnd, tEnd, since)
        let t = max(since - BEAT - RISE, 0)   // the same instant on both screens: one circle
        let side = fx.side.horizontal
        let phoneMm = (side ? w : h) / ptPerMm
        let scale = (side ? Seam.macW : Seam.macH) / phoneMm
        front = (0.04 + lk.reach * (1 - exp(-t / 0.22))) * scale   // the rim keeps travelling, slowing down
        flash = lk.flash * smooth(0, 0.05, t) * exp(-max(t - hold, 0) / lk.flashTau) * end
        ring = 0.7 * smooth(0, 0.03, t) * exp(-max(t - 0.22, 0) / 0.2) * end
        veil = 0.14 * lk.flash / 4 * smooth(0, 0.03, t) * exp(-t / 0.09)
    }
    if burst && !fx.strong {   // the light drains into the seam and the bands leave through it
        let end = 1 - smooth(0.385, 0.7, since)
        head += 0.5 * smooth(0, 0.5, since)
        fan *= exp(-since / 0.22) * end
        bloom *= exp(-since / 0.16) * end
        dim *= exp(-since / 0.25) * end
        k = lerp(k, 1, smooth(0, 0.08, since))
    } else if burst {          // inhale for one beat, then the tile leaves and the fan swings away as the dome opens
        let tEnd = lk.dissolve, hold = lk.flashHold
        let end = 1 - smooth(0.55 * tEnd, tEnd, since)
        let pre = smooth(0, BEAT, since) * (1 - smooth(BEAT, BEAT + 0.05, since))
        bloomR *= 1 - 0.45 * pre
        bloom *= 1 + 0.6 * pre
        dim *= 1 + 0.25 * pre
        let t = max(since - BEAT, 0)
        head -= 0.95 * smooth(0.03, 0.75, t)
        tail = smooth(0.04, 0.35, t)
        cool = smooth(0.2, 0.5, t)
        pale *= 1 - smooth(0, 0.2, t)
        wid = lerp(wid, 0.34, smooth(0.1, 0.7, t))
        fan *= exp(-max(t - 0.6 * hold, 0) / (0.3 * tEnd)) * end
        reach = lerp(reach, 2.4, smooth(0, 0.2, t))
        bloom *= exp(-max(t - hold, 0) / 0.2) * end
        dim *= (1 - 0.45 * smooth(0, 0.15, t)) * exp(-max(t - 0.5 * hold, 0) / (0.25 * tEnd)) * end
    }

    let s = fx.side
    let ln = s.horizontal ? w : h   // inward length
    let lc = s.horizontal ? h : w   // edge length
    fx.seed = fx.seed >= 251 ? 0 : fx.seed + 1
    var u = LightUniforms()
    u.origin = SIMD2(0.42 * 1.6 + 0.02 * sin(tt * 0.3), -2.1)
    u.side = { switch s { case .right: return 0; case .left: return 1; case .top: return 2; case .bottom: return 3 } }()
    u.along = min(max((s.horizontal ? fx.cy : fx.cx) / lc, 0), 1)
    u.k = lc / (ln / 1.6)
    u.head = head; u.wid = wid
    u.fan = fan * k; u.pale = pale; u.reach = reach
    u.bloom = bloom * (0.5 + 0.5 * k); u.bloomR = bloomR
    u.dimK = dim * k
    u.flash = flash * k; u.front = front; u.ring = ring * k
    u.veil = veil * k; u.tail = tail; u.cool = cool
    u.sat = lk.sat; u.contrast = lk.contrast; u.disp = lk.disp
    u.warp = lk.warp * (1 + 1.5 * energy); u.grain = lk.grain; u.streak = lk.streak
    u.time = tt * 2.6; u.seed = fx.seed
    return u
}

/// Pipelines are built once, off the main thread, so neither launch nor the first drag stalls. Frames are skipped until then.
final class FxGPU {
    static let device = MTLCreateSystemDefaultDevice()
    private(set) static var shared: FxGPU?
    private static var started = false

    static func prepare() {
        guard !started else { return }
        started = true
        DispatchQueue.global(qos: .userInitiated).async {
            let g = FxGPU()
            DispatchQueue.main.async { shared = g }
        }
    }

    let queue: MTLCommandQueue
    let light: MTLRenderPipelineState
    let pair: MTLRenderPipelineState

    private init?() {
        guard let dev = FxGPU.device, let q = dev.makeCommandQueue(),
              let lib = try? dev.makeLibrary(source: FxShaders.source, options: nil) else { return nil }
        func pipe(_ fragment: String) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "fx_vertex")
            d.fragmentFunction = lib.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try? dev.makeRenderPipelineState(descriptor: d)
        }
        guard let l = pipe("light_fragment"), let p = pipe("pair_fragment") else { return nil }
        queue = q; light = l; pair = p
    }
}

/// A transparent Metal layer drawn at 1.5× points: the field has no fine detail. Skips a frame rather than ever waits.
final class FxView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var ml: CAMetalLayer { layer as! CAMetalLayer }
    private let inFlight = DispatchSemaphore(value: 2)

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        ml.device = FxGPU.device
        ml.pixelFormat = .bgra8Unorm
        ml.isOpaque = false
        ml.framebufferOnly = true
        ml.maximumDrawableCount = 3
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        ml.drawableSize = CGSize(width: max(bounds.width * 1.5, 1), height: max(bounds.height * 1.5, 1))
    }

    var pixelSize: SIMD2<Float> { SIMD2(Float(ml.drawableSize.width), Float(ml.drawableSize.height)) }

    func draw<U>(_ pipe: MTLRenderPipelineState, _ uniforms: U) {
        guard let gpu = FxGPU.shared, inFlight.wait(timeout: .now()) == .success else { return }
        guard let drawable = ml.nextDrawable(), let cmd = gpu.queue.makeCommandBuffer() else { inFlight.signal(); return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { inFlight.signal(); return }
        enc.setRenderPipelineState(pipe)
        var u = uniforms
        enc.setFragmentBytes(&u, length: MemoryLayout<U>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        let sem = inFlight
        cmd.addCompletedHandler { _ in sem.signal() }
        cmd.present(drawable)
        cmd.commit()
    }

    func draw(light u: LightUniforms) {
        guard let p = FxGPU.shared?.light else { return }
        var u = u
        u.size = pixelSize
        draw(p, u)
    }

    func draw(pair u: PairUniforms) {
        guard let p = FxGPU.shared?.pair else { return }
        var u = u
        u.size = pixelSize
        draw(p, u)
    }
}

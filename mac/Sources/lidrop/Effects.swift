import AppKit
import Metal
import QuartzCore

/// Critically damped spring, integrated exactly so any frame time is stable. ω = 3.9 / T settles 90 % of the way in T.
struct Spring {
    var x = 0.0, v = 0.0
    mutating func step(to g: Double, w: Double, dt: Double) {
        let d = x - g, c = v + w * d, e = exp(-w * dt)
        x = g + (d + c * dt) * e
        v = (c - w * (d + c * dt)) * e
    }
}

/// One switchable look of the light field (LIDROP_LOOK=A|B|C or the "Light look" menu). Keep in step with `LOOKS` in Light.kt.
struct LightLook {
    var gain: Double       // ray strength before tone mapping
    var sat: Double        // 0 white, 1 the raw spectrum
    var contrast: Double   // shaft sharpness, the exponent on the shaft pattern
    var disp: Double       // chromatic dispersion along the ray
    var warp: Double       // organic bend of the shafts
    var grain: Double      // film grain, in 8-bit steps at full light
    var dim: Double        // wallpaper dimming far from the tile
    var bloom: Double      // bloom strength at full charge
    var bloomR: Double     // bloom radius gained at full charge
    var pale: Double       // how far the entry side of the fan washes to white
    var streak: Double     // anamorphic streak through the bloom
    var flash: Double      // peak of the landing flash; above ~3 it rolls off to white
    var flashTau: Double   // flash decay after the hold (s)
    var flashHold: Double  // how long the dome stays up (s)
    var reach: Double      // final radius of the flash front
    var dissolve: Double   // seconds from commit until the field is fully gone

    static let all: [String: LightLook] = [
        "A": LightLook(gain: 0.62, sat: 0.52, contrast: 1.4, disp: 0.7, warp: 0.8, grain: 1.2, dim: 0.18, bloom: 0.55, bloomR: 0.20, pale: 0.55, streak: 0, flash: 2.0, flashTau: 0.08, flashHold: 0.08, reach: 0.80, dissolve: 1.0),
        "B": LightLook(gain: 1.05, sat: 0.48, contrast: 1.0, disp: 1.0, warp: 0.7, grain: 1.2, dim: 0.68, bloom: 1.30, bloomR: 0.26, pale: 0.80, streak: 0, flash: 4.0, flashTau: 0.09, flashHold: 0.12, reach: 1.05, dissolve: 1.0),
        "C": LightLook(gain: 1.90, sat: 0.84, contrast: 1.9, disp: 1.5, warp: 1.2, grain: 2.2, dim: 0.76, bloom: 1.50, bloomR: 0.34, pale: 0.90, streak: 0.20, flash: 7.0, flashTau: 0.10, flashHold: 0.16, reach: 1.15, dissolve: 1.5),
    ]
    static let names = ["A", "B", "C"]
    static let titles = ["A": "A — subtle pastel", "B": "B — reference", "C": "C — dramatic"]
    static let envName = ProcessInfo.processInfo.environment["LIDROP_LOOK"]?.uppercased()
    static var currentName: String {
        get {
            if let n = envName, all[n] != nil { return n }
            let saved = UserDefaults.standard.string(forKey: "lightLook") ?? "B"
            return all[saved] != nil ? saved : "B"
        }
        set { UserDefaults.standard.set(newValue, forKey: "lightLook") }
    }
    static var current: LightLook { all[currentName]! }
}

/// "Light effects v5" (docs/PROTOCOL.md). One full-screen fragment shader computes one continuous light field per pixel:
/// shafts fanning from a single point beyond the top of the screen, bloom at the tile and the landing flash, added as
/// HDR radiance and tone mapped with 1 − exp(−x). Output is premultiplied (light in rgb, wallpaper occlusion in alpha),
/// so it screens over whatever is behind the panel. CPU work per tick is a dozen scalars and rendering runs on its own
/// queue, so a late drawable can never hold up the main thread that handles drag_move.
final class LightFX {
    static func ss(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
    static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    static let beat = 0.09    // seconds of inhale after the commit
    static let shrinkAt = 0.55   // seconds after commit: the tile shrinks away where it landed
    static let rise = 0.22    // the tile flies first: the dome only opens as it arrives

    /// Must match `U` in `source`.
    struct Uniforms {
        var size = SIMD2<Float>(1, 1)
        var origin = SIMD2<Float>(0, 0)   // the single point of the rays, in shader units
        var side: Int32 = 0               // entry edge: 0 right, 1 left, 2 top, 3 bottom
        var along: Float = 0.5            // tile position along the entry edge, 0…1
        var k: Float = 1                  // edge length / (inward length / 1.6): keeps bloom and flash round
        var head: Float = 0               // angle of the fan's entry-side end (radians, 0 = straight away from the point)
        var wid: Float = 1                // angular width of the spectrum
        var fan: Float = 0, pale: Float = 0, reach: Float = 2
        var bloom: Float = 0, bloomR: Float = 0.2
        var dim: Float = 0
        var flash: Float = 0, front: Float = 0, ring: Float = 0, veil: Float = 0, tail: Float = 0, cool: Float = 0
        var sat: Float = 0.6, contrast: Float = 1.5, disp: Float = 1, warp: Float = 1, grain: Float = 1, streak: Float = 0
        var time: Float = 0, seed: Float = 0
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct U { float2 size, origin; int side; float along, k, head, wid, fan, pale, reach, bloom, bloomR, dim, flash, front, ring, veil, tail, cool, sat, contrast, disp, warp, grain, streak, time, seed; };
    struct V { float4 pos [[position]]; };
    vertex V vs(uint i [[vertex_id]]) {
        float2 p = float2((i << 1) & 2, i & 2);
        V o; o.pos = float4(p * 2 - 1, 0, 1); return o;
    }
    float wob(float x, float t) {
        return (sin(x + t * 0.31) + 0.7 * sin(x * 2.17 - t * 0.23 + 1.3) + 0.45 * sin(x * 4.31 + t * 0.17 + 4.1)) / 2.15;
    }
    float shafts(float th, float r, float t, float warp, float contrast) {
        float w = th + warp * (0.05 * sin(r * 2.7 - t * 0.19 + th * 5.0) + 0.025 * sin(r * 5.9 + t * 0.13 - th * 11.0));
        float broad = 0.5 + 0.5 * wob(w * 4.5, t);
        float fine = 0.5 + 0.5 * wob(w * 9.0 + 1.7, t * 1.4);
        return 0.7 + 0.8 * pow(broad * (0.72 + 0.28 * fine), contrast);
    }
    float3 spectrum(float a) {   // one smooth hue sweep, no knots: pink, red, amber, green, cyan, blue
        return 0.5 + 0.5 * cos(6.2832 * (0.72 * a - 0.09 - float3(0.0, 0.3333, 0.6667)));
    }
    float hash(float2 p) {
        p = fract(p * float2(0.1031, 0.1030));
        p += dot(p, p.yx + 33.33);
        return fract((p.x + p.y) * p.x);
    }
    fragment float4 fs(V in [[stage_in]], constant U& u [[buffer(0)]]) {
        float2 uv = in.pos.xy / u.size;
        float2 q = u.side == 0 ? uv : u.side == 1 ? float2(1 - uv.x, uv.y) : u.side == 2 ? float2(1 - uv.y, uv.x) : uv.yx;
        float x = q.x * 1.6, y = q.y, t = u.time;
        float2 r = float2(x, y) - u.origin;
        float rad = length(r), th = 2.6 * atan2(r.x, r.y);   // the point is far, so bands stay near vertical; 2.6 keeps the angular scale
        float dx = 1.6 - x, dy = (y - u.along) * u.k;
        float d = sqrt(dx * dx + dy * dy);
        float dd = sqrt((dx + 0.7) * (dx + 0.7) + dy * dy) - 0.7;   // the dome is centred beyond the edge, so its rim is a shallow arc
        th += u.ring * 0.05 * exp(-(d - u.front) * (d - u.front) / 0.05);   // the wave front shoves the shafts as it passes
        // chromatic dispersion: each channel reads the field a little further along and across the ray
        float da = 0.012 * u.disp, dr = 0.05 * u.disp;
        float3 S = float3(shafts(th - da, rad * (1 + dr), t, u.warp, u.contrast),
                          shafts(th, rad, t, u.warp, u.contrast),
                          shafts(th + da, rad * (1 - dr), t, u.warp, u.contrast));
        float3 D = d * (1 + 0.035 * u.disp * float3(-1, 0, 1));
        float a = (th - (u.head - u.wid)) / u.wid + 0.05 * u.warp * wob(th * 6.0, t);
        float win = smoothstep(-0.2, 0.3, a) * (1 - u.tail * smoothstep(0.55, 1.5, a));
        float3 col = mix(float3(1), spectrum(a), u.sat);
        col = mix(col, float3(1.0, 0.98, 0.95), u.pale * smoothstep(0.42, 0.72, a));
        col = mix(col, float3(0.50, 0.92, 0.84), u.cool);   // what lingers after the ring is cold light
        float haze = 0.78 + 0.22 * wob(rad * 3.0 + th * 2.0, t * 0.7);
        float near = 1 - smoothstep(u.reach - 0.65, u.reach + 0.45, d);
        float band = 0.5 + 0.5 * exp(-(y - u.along) * (y - u.along) / 0.25);   // light gathers at the tile's height, not along the top edge
        float3 X = col * S * u.fan * win * near * haze * band;
        float R2 = u.bloomR * u.bloomR;
        X += u.bloom * (0.72 * exp(-D * D / R2) + 0.5 * exp(-D * D / (R2 * 0.16))) * float3(1.0, 0.98, 0.95);
        X += u.streak * u.bloom * exp(-dy * dy / 0.01) * exp(-dx * dx / 0.9) * float3(0.62, 0.78, 1.0);
        float3 over = max(dd * (1 + 0.015 * u.disp * float3(1, 0, -1)) - u.front, 0.0);
        float fe = 0.05 + 0.07 * u.front;
        X += u.flash * exp(-over * over / (fe * fe)) * float3(1.0, 0.95, 1.0) + u.veil;
        float3 rr = (dd * (1 + 0.032 * u.disp * float3(1, 0, -1)) - u.front - 0.6 * fe) / (0.014 + 0.07 * u.front);   // the dome's rainbow rim, red inside, blue outside
        X += u.ring * exp(-rr * rr) * mix(float3(1), float3(0.62, 0.88, 1.0), u.cool);
        float3 L = 1 - exp(-X);   // filmic roll-off: highlights approach white instead of clipping flat
        float peak = max(L.r, max(L.g, L.b));
        float cover = mix(dot(L, float3(0.2126, 0.7152, 0.0722)), peak, 0.8);   // alpha is one number, so screen is approximated
        cover = pow(cover, 1 + 0.9 * u.tail);   // dissolving light must not leave a grey veil over the wallpaper
        float T = (1 - u.dim * (1 - 0.8 * near) * (1 - peak)) * (1 - cover);
        float n = hash(in.pos.xy + u.seed * float2(37.0, 17.0)) + hash(in.pos.xy.yx + u.seed * float2(11.0, 53.0)) - 1;   // triangular
        L += n * (1 + u.grain * sqrt(peak)) / 255.0;
        return float4(max(L, 0.0), clamp(1 - T + n / 255.0, 0.0, 1.0));
    }
    """

    /// Rendering statistics, gathered only when `collect` is set (LIDROP_DEBUG_FX), printed by the overlay after each drag.
    final class Stats {
        let lock = NSLock()
        var gpuMs: [Double] = []
        var skipped = 0
        func add(_ ms: Double) { lock.lock(); gpuMs.append(ms); lock.unlock() }
        func take() -> (gpu: [Double], skipped: Int) {
            lock.lock(); defer { lock.unlock() }
            let r = (gpuMs, skipped); gpuMs = []; skipped = 0
            return r
        }
    }

    let metal = CAMetalLayer()
    var queue: MTLCommandQueue?
    var pipeline: MTLRenderPipelineState?
    var u = Uniforms()
    var look = LightLook.current
    var peak = 0.0            // highest charge since the drag began, read by the commit
    var strength = 1.0        // 1 on the receiving screen, lower on the sender
    var hidden = true
    var collect = false
    var sender = false        // this screen hands the light over; the other screen's flash answers it
    var energy = 0.0          // 0…1, how fast the drag is moving right now
    var armedAge = -1.0       // seconds since the drag crossed the commit line, negative = not armed
    let stats = Stats()
    let renderQueue = DispatchQueue(label: "lidrop.light", qos: .userInteractive)
    let inFlight = DispatchSemaphore(value: 2)

    func prepare(device: MTLDevice, format: MTLPixelFormat) {
        queue = device.makeCommandQueue()
        do {
            let lib = try device.makeLibrary(source: LightFX.source, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "vs")
            d.fragmentFunction = lib.makeFunction(name: "fs")
            d.colorAttachments[0].pixelFormat = format
            pipeline = try device.makeRenderPipelineState(descriptor: d)
        } catch {
            NSLog("lidrop: light shader failed: \(error)")
        }
    }

    func install(in root: CALayer) {
        metal.actions = ["opacity": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull(), "contents": NSNull()]
        metal.isOpaque = false
        metal.isHidden = true
        metal.pixelFormat = .bgra8Unorm
        metal.zPosition = -10   // the tile sits above the light
        metal.contentsScale = ProcessInfo.processInfo.environment["LIDROP_LIGHT_SCALE"].flatMap { Double($0) }.map { CGFloat($0) } ?? 1   // the field is smooth: 1× costs ~40 % of 2× on the GPU with no visible loss
        metal.framebufferOnly = true
        metal.allowsNextDrawableTimeout = true
        root.addSublayer(metal)
        guard let device = MTLCreateSystemDefaultDevice() else { NSLog("lidrop: no Metal device, light disabled"); return }
        metal.device = device
        prepare(device: device, format: .bgra8Unorm)
    }

    func start() { peak = 0; look = LightLook.current }

    func stop() { hideAll() }

    func hideAll() {
        metal.isHidden = true
        hidden = true
    }

    /// Fills `u` for one instant. p = charge 0…1; since = seconds since commit (negative = not committed).
    func compute(edge: String, along: Double, w: CGFloat, h: CGFloat, p: Double, since: Double, t: Double) {
        let burst = since >= 0
        let vertical = edge == "left" || edge == "right"
        let L = vertical ? w : h, S = vertical ? h : w
        let ss = LightFX.ss, mix = LightFX.mix
        let lk = look

        // charge: the fan swings from the far side toward the entry edge and narrows, the bloom gathers at the tile
        let q = burst ? max(peak, 0.6) : p
        let P = ss(0, 1, q)
        let breath = sin(t * 1.9)
        let lean = 0.25 * (along - 0.5)   // the bands lean with the tile as it slides along the edge
        var head = -0.05 + 1.29 * P + lean   // the colours start at the far side and sweep to the seam
        var wid = 0.95 + 0.25 * P
        var fan = lk.gain * ss(0.05, 0.35, q) * (1 + 0.06 * breath) * (1 + 0.25 * energy)
        var pale = lk.pale * ss(0.4, 1, q)
        var reach = 1.9 - 0.8 * P
        var bloom = 1.35 * lk.bloom * P * (0.4 + 0.6 * P) * (1 + 0.08 * sin(t * 1.9 + 0.6))   // a stronger white at the tile
        var bloomR = 0.2 + 1.2 * lk.bloomR * P
        var dim = lk.dim * ss(0.08, 0.9, q)
        var flash = 0.0, front = 0.0, ring = 0.0, veil = 0.0, tail = 0.0, cool = 0.0
        var k = strength
        if !burst && armedAge >= 0 {   // crossing the commit line: one quiet pulse says "you can let go"
            let e = ss(0, 0.04, armedAge) * exp(-armedAge / 0.42)
            bloom *= 1 + 0.9 * e
            ring = 0.35 * e
            front = 0.05 + 0.95 * (1 - exp(-armedAge / 0.3))
        }
        if burst {   // both screens show the same dome, centred on the seam, at the same physical size
            let T = lk.dissolve, h = lk.flashHold
            let end = 1 - ss(0.55 * T, T, since)
            let d = max(since - LightFX.beat - LightFX.rise, 0)   // the same instant on both screens: one circle
            front = 0.04 + lk.reach * (1 - exp(-d / 0.13))   // the rim keeps travelling, slowing down
            flash = lk.flash * ss(0, 0.05, d) * exp(-max(d - h, 0) / lk.flashTau) * end
            ring = 0.8 * ss(0, 0.03, d) * exp(-max(d - 0.22, 0) / 0.2) * end
            veil = 0.14 * lk.flash / 4 * ss(0, 0.03, d) * exp(-d / 0.09)
        }
        if burst && sender {   // the light drains into the seam and the bands leave through it
            let end = 1 - ss(0.385, 0.7, since)
            head += 0.5 * ss(0, 0.5, since)
            fan *= exp(-since / 0.18) * end
            bloom *= exp(-since / 0.16) * end
            dim *= exp(-since / 0.18) * end
            k = mix(k, 1, ss(0, 0.08, since))
        } else if burst {   // inhale for one beat, then the tile leaves and the fan swings away as the dome opens
            let T = lk.dissolve, h = lk.flashHold
            let end = 1 - ss(0.55 * T, T, since)
            let pre = ss(0, LightFX.beat, since) * (1 - ss(LightFX.beat, LightFX.beat + 0.05, since))
            bloomR *= 1 - 0.45 * pre
            bloom *= 1 + 0.6 * pre
            dim *= 1 + 0.25 * pre
            let s = max(since - LightFX.beat, 0)
            head -= 0.95 * ss(0.02, 0.4, s)
            tail = ss(0.04, 0.35, s)
            cool = ss(0.2, 0.5, s)
            pale *= 1 - ss(0, 0.2, s)
            wid = mix(wid, 0.34, ss(0.1, 0.4, s))
            fan *= exp(-max(s - 0.6 * h, 0) / (0.3 * T)) * end
            reach = mix(reach, 2.4, ss(0, 0.2, s))
            bloom *= exp(-max(s - h, 0) / 0.2) * end
            dim *= (1 - 0.45 * ss(0, 0.15, s)) * exp(-max(s - 0.5 * h, 0) / (0.25 * T)) * end
        }

        let sideIndex: Int32 = edge == "right" ? 0 : edge == "left" ? 1 : edge == "top" ? 2 : 3
        let scale = metal.contentsScale
        u.size = SIMD2(Float(w * scale), Float(h * scale))
        u.origin = SIMD2(Float(0.42 * 1.6 + 0.02 * sin(t * 0.3)), -2.1)
        u.side = sideIndex
        u.along = Float(along)
        u.k = Float(S / (L / 1.6))
        u.head = Float(head); u.wid = Float(wid)
        u.fan = Float(fan * k); u.pale = Float(pale); u.reach = Float(reach)
        u.bloom = Float(bloom * (0.5 + 0.5 * k)); u.bloomR = Float(bloomR)
        u.dim = Float(dim * k)
        u.flash = Float(flash * k); u.front = Float(front); u.ring = Float(ring * k); u.veil = Float(veil * k); u.tail = Float(tail); u.cool = Float(cool)
        u.sat = Float(lk.sat); u.contrast = Float(lk.contrast); u.disp = Float(lk.disp); u.warp = Float(lk.warp * (1 + 1.0 * energy))
        u.grain = Float(lk.grain); u.streak = Float(lk.streak)
        u.time = Float(t * 2.6); u.seed = u.seed >= 251 ? 0 : u.seed + 1
    }

    /// Per tick. c = tile center in panel coords (AppKit, y up).
    func update(edge: String, c: CGPoint, w: CGFloat, h: CGFloat, ts: CGFloat, p: Double, fx: Double, t: Double) {
        let burst = fx >= 0 && fx < look.dissolve
        if (p < 0.004 && !burst) || fx >= look.dissolve {   // once dissolved, a draining p must not redraw the charge
            if !hidden { hideAll() }
            return
        }
        if hidden { metal.isHidden = false; hidden = false }
        peak = max(peak, p)
        let along: CGFloat
        switch edge {
        case "right", "left": along = 1 - c.y / h
        default: along = c.x / w
        }
        compute(edge: edge, along: Double(along), w: w, h: h, p: p, since: burst ? fx : -1, t: t)
        draw(w, h)
    }

    func encode(_ cb: MTLCommandBuffer, into texture: MTLTexture, uniforms: Uniforms) {
        guard let pipeline else { return }
        var uniforms = uniforms
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// Latest-wins: with two frames in flight the tick simply skips, it never waits.
    func draw(_ w: CGFloat, _ h: CGFloat) {
        let frame = CGRect(x: 0, y: 0, width: w, height: h)
        if metal.frame != frame { metal.frame = frame }
        let px = CGSize(width: w * metal.contentsScale, height: h * metal.contentsScale)
        if metal.drawableSize != px { metal.drawableSize = px }
        guard inFlight.wait(timeout: .now()) == .success else {
            if collect { stats.lock.lock(); stats.skipped += 1; stats.lock.unlock() }
            return
        }
        let snapshot = u
        renderQueue.async { [self] in
            guard let queue, let drawable = metal.nextDrawable(), let cb = queue.makeCommandBuffer() else {
                inFlight.signal()
                return
            }
            encode(cb, into: drawable.texture, uniforms: snapshot)
            cb.present(drawable)
            let collect = self.collect
            cb.addCompletedHandler { [self] b in
                if collect { stats.add((b.gpuEndTime - b.gpuStartTime) * 1000) }
                inFlight.signal()
            }
            cb.commit()
        }
    }
}

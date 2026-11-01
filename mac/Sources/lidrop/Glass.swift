import AppKit
import Metal
import QuartzCore

/// The connect ceremony on the Mac: one piece of liquid glass spanning the seam. A lens swells at the edge while the phone
/// is held, then one wave leaves the seam. The phones draw the same lens and wave (Pair.kt, Shaders.swift) in the same
/// millimetres on the same clock, so the two screens read as one surface.
final class GlassFX {
    struct U {
        var size = SIMD2<Float>(), seam = SIMD2<Float>()
        var mmPerPx: Float = 0, men: Float = 0, front: Float = -1, fade: Float = 1
    }

    /// Radius of the wave in mm, `t` seconds after it starts. Same on every screen.
    static func frontMm(_ t: Double, macW: Double) -> Double { 0.66 * macW * (1 - exp(-t / 0.30)) }

    /// Radius of the lens in mm for a hold of `p` (0…1). Same on every screen.
    static func lensMm(_ p: Double) -> Double { 10 + 24 * p }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct U { float2 size, seam; float mmPerPx, men, front, fade; };
    struct V { float4 pos [[position]]; };
    vertex V vs(uint i [[vertex_id]]) {
        float2 p = float2((i << 1) & 2, i & 2);
        return { float4(p * 2.0 - 1.0, 0.0, 1.0) };
    }
    fragment float4 fs(V in [[stage_in]], constant U &u [[buffer(0)]]) {
        float2 q = (in.pos.xy - u.seam) * u.mmPerPx;
        float d = length(q);
        float light = 0.0, cover = 0.0;
        if (u.men > 0.0) {
            float mask = 1.0 - smoothstep(-0.4, 0.4, d - u.men);
            float2 nq = q / u.men;
            float z = sqrt(max(1.0 - dot(nq, nq), 0.0));
            float3 n = float3(nq, z);
            float fres = pow(1.0 - z, 3.0);
            float s = max(dot(n, normalize(float3(-0.42, -0.62, 0.66))), 0.0);
            light = mask * (0.03 + 0.42 * fres + 0.75 * pow(s, 70.0) + 0.1 * pow(s, 6.0));
            cover = mask * (0.08 + 0.3 * fres);
        }
        if (u.front >= 0.0) {
            float w = 2.5 + 0.05 * u.front;
            float x = (d - u.front) / (w * 0.7);
            float rim = exp(-x * x) * u.fade;
            light += rim * 0.42;
            cover = max(cover, rim * 0.42);
        }
        float3 c = light * float3(0.92, 0.95, 1.0);
        return float4(c, clamp(cover, 0.0, 1.0));
    }
    """

    let metal = CAMetalLayer()
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private let inFlight = DispatchSemaphore(value: 2)

    func install(in root: CALayer) {
        metal.actions = ["opacity": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull(), "contents": NSNull()]
        metal.isOpaque = false
        metal.isHidden = true
        metal.pixelFormat = .bgra8Unorm
        metal.zPosition = -9
        metal.contentsScale = 2   // a thin rim: unlike the soft light field it needs the pixels
        metal.framebufferOnly = true
        metal.allowsNextDrawableTimeout = true
        root.addSublayer(metal)
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        metal.device = device
        queue = device.makeCommandQueue()
        do {
            let lib = try device.makeLibrary(source: GlassFX.source, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "vs")
            d.fragmentFunction = lib.makeFunction(name: "fs")
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: d)
        } catch { NSLog("lidrop: glass shader failed: \(error)") }
    }

    func hide() { metal.isHidden = true }

    /// `seam` in points from the top left; lengths in mm. Skips a frame rather than ever waits.
    func draw(w: CGFloat, h: CGFloat, seam: CGPoint, mmPerPt: Double, men: Double, front: Double, fade: Double) {
        let frame = CGRect(x: 0, y: 0, width: w, height: h)
        if metal.frame != frame { metal.frame = frame }
        let k = metal.contentsScale, px = CGSize(width: w * k, height: h * k)
        if metal.drawableSize != px { metal.drawableSize = px }
        metal.isHidden = false
        guard let queue, let pipeline, inFlight.wait(timeout: .now()) == .success else { return }
        guard let drawable = metal.nextDrawable(), let cb = queue.makeCommandBuffer() else { inFlight.signal(); return }
        var u = U(size: SIMD2(Float(px.width), Float(px.height)), seam: SIMD2(Float(seam.x * k), Float(seam.y * k)),
                  mmPerPx: Float(mmPerPt / Double(k)), men: Float(men), front: Float(front), fade: Float(fade))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { inFlight.signal(); return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<U>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.present(drawable)
        let sem = inFlight
        cb.addCompletedHandler { _ in sem.signal() }
        cb.commit()
    }
}

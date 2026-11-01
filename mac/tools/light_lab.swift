// Test aid: renders the real light shader offscreen on a scripted timeline, composited over a backdrop PNG, and times it.
// usage: swiftc -parse-as-library mac/tools/light_lab.swift mac/Sources/lidrop/Effects.swift -o /tmp/light_lab
//        /tmp/light_lab frames <outdir> <look A|B|C> <backdrop.png> [width height]   writes t_<ms>.jpg
//        /tmp/light_lab bench <look A|B|C> <width> <height> [frames]                 prints GPU ms per frame
import AppKit
import Metal

/// The same drag as tools/fake_phone_demo.py up to the commit: approach, hold, then land.
func overhang(_ t: Double) -> Double {
    t < 1.6 ? 0.8 * t / 1.6 : t < 2.6 ? 0.8 : 0.8 + 0.2 * min((t - 2.6) / 0.2, 1)
}
let commitAt = 2.8

func run(_ fx: LightFX, cb: (Double, Double) -> Void) {   // calls back with (time, since commit)
    var s = Spring()
    var t = 0.0
    let dt = 1.0 / 60
    while t < commitAt + fx.look.dissolve + 0.1 {
        let committed = t >= commitAt
        let o = overhang(t)
        let g = committed ? (t < commitAt + 0.25 ? 1 : 0) : fx.sender ? LightFX.ss(0, 0.25, o) * (1 - 0.55 * LightFX.ss(0.25, 1, o)) : LightFX.ss(0, 0.5, o)
        s.step(to: g, w: committed ? (g > s.x ? 30 : 8) : (g > s.x ? 3.9 : 8.6), dt: dt)
        fx.peak = max(fx.peak, s.x)
        fx.compute(edge: fx.sender ? "left" : "right", along: 0.45, w: 1, h: 1, p: s.x, since: committed ? t - commitAt : -1, t: t + 3)
        cb(t, committed ? t - commitAt : -1)
        t += dt
    }
}

@main struct Lab {
    static func main() {
        let a = CommandLine.arguments
        let device = MTLCreateSystemDefaultDevice()!
        let fx = LightFX()
        fx.prepare(device: device, format: .rgba8Unorm)
        let bench = a[1] == "bench"
        fx.look = LightLook.all[bench ? a[2] : a[3]]!
        fx.sender = ProcessInfo.processInfo.environment["LAB_SENDER"] != nil
        let w = Int(a.count > (bench ? 3 : 5) ? a[bench ? 3 : 5] : "1280")!
        let h = Int(a.count > (bench ? 4 : 6) ? a[bench ? 4 : 6] : "832")!
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        let tex = device.makeTexture(descriptor: d)!
        fx.metal.contentsScale = 1

        func render() -> MTLCommandBuffer {
            var u = fx.u
            u.size = SIMD2(Float(w), Float(h))
            let cb = fx.queue!.makeCommandBuffer()!
            fx.encode(cb, into: tex, uniforms: u)
            cb.commit()
            cb.waitUntilCompleted()
            return cb
        }

        if bench {
            var ms: [Double] = []
            run(fx) { _, _ in
                let cb = render()
                ms.append((cb.gpuEndTime - cb.gpuStartTime) * 1000)
            }
            ms.sort()
            print(String(format: "look %@ %dx%d frames=%d gpu ms p50=%.2f p99=%.2f max=%.2f", a[2], w, h, ms.count,
                         ms[ms.count / 2], ms[ms.count * 99 / 100], ms.last!))
            return
        }

        let out = a[2]
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let back = NSImage(contentsOfFile: a[4])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let cs = CGColorSpaceCreateDeviceRGB()
        var n = 0
        run(fx) { t, _ in
            n += 1
            if n % 2 != 0 { return }
            _ = render()
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(back, in: CGRect(x: 0, y: 0, width: w, height: h))
            let light = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: cs,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false,
                                intent: .defaultIntent)!
            ctx.draw(light, in: CGRect(x: 0, y: 0, width: w, height: h))
            let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
            let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])!
            try? data.write(to: URL(fileURLWithPath: "\(out)/t_\(String(format: "%05d", Int(t * 1000))).jpg"))
        }
    }
}

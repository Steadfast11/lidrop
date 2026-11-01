// usage: swiftc mac/tools/make_icon.swift -o /tmp/make_icon && /tmp/make_icon <out.iconset dir>
// Two overlapping rounded rectangles (phone + Mac screen) on a dark rounded square.
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    func rr(_ r: CGRect, _ rad: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil) }
    let bg = rr(CGRect(x: s * 0.05, y: s * 0.05, width: s * 0.9, height: s * 0.9), s * 0.2)
    ctx.addPath(bg); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [CGColor(red: 0.10, green: 0.12, blue: 0.20, alpha: 1), CGColor(red: 0.20, green: 0.27, blue: 0.50, alpha: 1)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: s, y: s), options: [])
    // back: Mac screen
    ctx.setFillColor(CGColor(red: 0.85, green: 0.90, blue: 1, alpha: 0.95))
    ctx.addPath(rr(CGRect(x: s * 0.17, y: s * 0.30, width: s * 0.46, height: s * 0.42), s * 0.07)); ctx.fillPath()
    // front: phone, overlapping, with shadow
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.02), blur: s * 0.05, color: CGColor(gray: 0, alpha: 0.45))
    ctx.setFillColor(CGColor(red: 1.0, green: 0.55, blue: 0.20, alpha: 1))
    ctx.addPath(rr(CGRect(x: s * 0.46, y: s * 0.24, width: s * 0.26, height: s * 0.48), s * 0.06)); ctx.fillPath()
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}

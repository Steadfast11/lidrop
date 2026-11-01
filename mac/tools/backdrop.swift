// Test aid: full-screen borderless bright cyan/blue backdrop (like the drooop demo wallpaper) so the light effects
// can be judged against a bright base without touching the real wallpaper. Click-through; quit with: pkill -x backdrop
// usage: swiftc mac/tools/backdrop.swift -o /tmp/backdrop && /tmp/backdrop
import AppKit

final class V: NSView {
    override func draw(_ r: NSRect) {
        let g = NSGradient(colors: [NSColor(red: 0.05, green: 0.17, blue: 0.24, alpha: 1), NSColor(red: 0.10, green: 0.50, blue: 0.62, alpha: 1),
                                    NSColor(red: 0.16, green: 0.78, blue: 0.90, alpha: 1)], atLocations: [0, 0.5, 1], colorSpace: .deviceRGB)!
        g.draw(in: bounds, angle: 90)
        // mountains
        let w = bounds.width, h = bounds.height
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 0, y: 0)); p.line(to: NSPoint(x: 0, y: h * 0.38))
        for (x, y) in [(0.12, 0.50), (0.22, 0.44), (0.34, 0.62), (0.45, 0.50), (0.58, 0.45), (0.72, 0.40), (1.0, 0.34)] {
            p.line(to: NSPoint(x: w * x, y: h * y))
        }
        p.line(to: NSPoint(x: w, y: 0)); p.close()
        NSColor(red: 0.04, green: 0.22, blue: 0.30, alpha: 1).setFill(); p.fill()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let f = NSScreen.main!.frame
let win = NSWindow(contentRect: f, styleMask: .borderless, backing: .buffered, defer: false)
win.contentView = V(frame: NSRect(origin: .zero, size: f.size))
win.level = .floating          // above normal windows, below the lidrop overlay (.screenSaver)
win.ignoresMouseEvents = true
win.collectionBehavior = [.canJoinAllSpaces, .stationary]
win.orderFrontRegardless()
app.run()

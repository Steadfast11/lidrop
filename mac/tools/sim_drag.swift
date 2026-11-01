// Simulates a Finder-style file drag: python-free CGEvent mouse drag + drag pasteboard.
// usage: swiftc tools/sim_drag.swift -o /tmp/sim_drag && /tmp/sim_drag <file[,file2,...]|folder> <edge: right|left|top|bottom> [commit:1|0] [hold-seconds]
import AppKit

let a = CommandLine.arguments
let files = a[1].split(separator: ",").map { URL(fileURLWithPath: String($0)) }   // comma-separated paths
let edge = a.count > 2 ? a[2] : "right"
let commit = a.count > 3 ? a[3] != "0" : true
let hold = a.count > 4 ? Double(a[4])! : 0
let f = NSScreen.main!.frame   // AppKit; CG uses top-left origin, same width/height for the main display
let W = f.width, H = f.height
func post(_ t: CGEventType, _ p: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}
// start in a quiet spot, end near/at the chosen edge
let start = CGPoint(x: W * 0.5, y: H * 0.8)
var end: CGPoint
switch edge {
case "left": end = CGPoint(x: commit ? 1 : 14, y: H * 0.8)
case "top": end = CGPoint(x: W * 0.5, y: commit ? 1 : 14)
case "bottom": end = CGPoint(x: W * 0.5, y: H - (commit ? 2 : 14))
default: end = CGPoint(x: W - (commit ? 2 : 14), y: H * 0.8)
}
post(.leftMouseDown, start)
usleep(100_000)
let pb = NSPasteboard(name: .drag)   // what a real drag source does after mouse down
pb.clearContents()
pb.writeObjects(files as [NSURL])
let steps = 90
for i in 1...steps {
    let t = Double(i) / Double(steps)
    post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
    usleep(16_000)
}
if hold > 0 { sleep(UInt32(hold)) }
post(.leftMouseUp, end)
print("sim drag done")

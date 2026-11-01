import UIKit

enum Side: String {
    case left, right, top, bottom
    var wire: String { rawValue }
    var horizontal: Bool { self == .left || self == .right }
}

let CHUNK = 256 * 1024
let TILE: CGFloat = 192
let EDGE_SLACK: CGFloat = 56
let DEFAULT_PORT: UInt16 = 7777
let APP_GROUP = "group.dev.lidrop.ios"

/// Shared with the Share extension, so it is the same trusted phone. A build without the App Group falls back to its own.
let prefs = UserDefaults(suiteName: APP_GROUP) ?? .standard

/// Cross-thread busy flags (drag / send / receive never overlap).
final class Flags {
    private let l = NSLock()
    private var d = false, s = false, r = false, want = -1
    var dragging: Bool { get { l.lock(); defer { l.unlock() }; return d } set { l.lock(); d = newValue; l.unlock() } }
    var sending: Bool { get { l.lock(); defer { l.unlock() }; return s } set { l.lock(); s = newValue; l.unlock() } }
    var receiving: Bool { get { l.lock(); defer { l.unlock() }; return r } set { l.lock(); r = newValue; l.unlock() } }
    /// Block the Mac's player is waiting for; reading it clears it.
    func setWant(_ b: Int) { l.lock(); want = b; l.unlock() }
    func takeWant() -> Int { l.lock(); defer { want = -1; l.unlock() }; return want }
}

/// The file's own shape, longest side `px`.
func shapeThumb(_ img: UIImage, px: CGFloat = 512) -> UIImage {
    let k = min(1, px / max(img.size.width, img.size.height, 1))
    let size = CGSize(width: max(1, (img.size.width * k).rounded()), height: max(1, (img.size.height * k).rounded()))
    let f = UIGraphicsImageRendererFormat()
    f.scale = 1; f.opaque = true
    return UIGraphicsImageRenderer(size: size, format: f).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
}

/// iPhones are ~326 ppi (@2x) or ~460 ppi (@3x modern); good enough for tile_mm / screen_mm and the dome.
func pointsPerMM(nativeScale: CGFloat) -> CGFloat {
    (nativeScale >= 3 ? 460 : 326) / nativeScale / 25.4
}

func pointsToMM(_ pt: CGFloat, nativeScale: CGFloat) -> Double {
    Double(pt / pointsPerMM(nativeScale: nativeScale))
}

func humanSize(_ b: Int64) -> String {
    if b >= 1 << 30 { return String(format: "%.1f GB", Double(b) / 1_073_741_824) }
    if b >= 1 << 20 { return String(format: "%.1f MB", Double(b) / 1_048_576) }
    if b >= 1 << 10 { return String(format: "%.0f KB", Double(b) / 1024) }
    return "\(b) B"
}

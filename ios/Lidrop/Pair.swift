import SwiftUI
import UIKit

private let DROP_R: CGFloat = 0.2    // of the screen width
private let DROP_Y: CGFloat = 0.62   // of the screen height: in the lower half, where the thumb rests

/// The lens and the wave, in mm: must stay the same as `GlassFX.lensMm` / `frontMm` on the Mac, or the screens stop matching.
private func lensMm(_ p: Float) -> Float { 10 + 24 * p }
private func frontMm(_ t: Float) -> Float { 0.66 * Seam.macW * (1 - exp(-t / 0.3)) }

private func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float { let t = min(max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t) }

/// The connect ceremony (docs/PROTOCOL.md "Connect ceremony"), seen once, the first time a computer allows this phone: a
/// drop of liquid glass on a dark screen. It fills by itself while the link comes up, and the wave only leaves the seam
/// once the computer has really answered.
final class PairDriver: NSObject, ObservableObject {
    @Published var failed = false
    @Published var denied = false
    @Published var bursting = false
    let field = FxView()
    var model: AppModel?
    var onOpen: (() -> Void)?
    var onDone: (() -> Void)?
    private var wasDenied = false
    private var fill: Float = 0, jelly: Float = 0.25, link: Float = 0
    private let t0 = CACurrentMediaTime()
    private var last = CACurrentMediaTime()
    private var startedAt = CACurrentMediaTime(), upAt: CFTimeInterval = -1, firedAt: CFTimeInterval = -1
    private var lastSend: CFTimeInterval = 0, sends = 0
    private var displayLink: CADisplayLink?

    func start() {
        guard displayLink == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(frame))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        displayLink = l
    }

    func stop() { displayLink?.invalidate(); displayLink = nil }

    func retry() {
        guard denied else { return }
        denied = false
        model?.connector.retry()
    }

    func usePairingCode(_ code: String) {
        failed = false
        startedAt = CACurrentMediaTime()
        model?.connector.connectManual(code)
    }

    @objc private func frame() {
        guard let m = model else { return }
        let now = CACurrentMediaTime()
        let dt = Float(min(now - last, 0.05))
        last = now
        let up = m.conn.isUp, active = !denied
        jelly += ((active ? 1 : 0.25) - jelly) * (1 - exp(-dt * 8))
        link += ((up && active ? 1 : 0) - link) * (1 - exp(-dt * 9))
        if firedAt < 0 {
            let no = m.conn == .failed(DENIED)
            if no && !wasDenied { denied = true }
            wasDenied = no
            if up && upAt < 0 { upAt = now; sends = 0; UISelectionFeedbackGenerator().selectionChanged() }
            if !up { upAt = -1 }
            if active {
                // it can only finish on a live link, and it stays short of full until there is one
                let cap = up ? min(0.86 + 0.14 * Float((now - upAt) / 0.45), 1) : 0.86
                fill = min(fill + dt / 1.1, max(cap, fill))
                if up && now - lastSend >= 0.033 {
                    lastSend = now
                    if sends % 8 == 0 {
                        m.client.pingAt = now
                        m.client.sendJson(["t": "pair", "state": "ping", "p": 0])
                    } else { m.client.sendJson(["t": "pair", "state": "hold", "p": Double(fill)]) }
                    sends += 1
                }
                if up && fill >= 1 { fire(now, m) }
                // it never gives up: the moment the computer appears, the connection goes through
                let lost = !up && m.connector.found.isEmpty && now - startedAt > 15
                if lost != failed { failed = lost }
            } else { fill = max(fill - dt / 0.3, 0) }
        }
        let ptPerMm = Float(pointsPerMM(nativeScale: field.window?.screen.nativeScale ?? 3))
        let w = Float(field.bounds.width), h = Float(field.bounds.height), asp = h / max(w, 1), mmW = max(w / ptPerMm, 1)
        let burst: Float = firedAt < 0 || now < firedAt ? -1 : Float(now - firedAt)
        var u = PairUniforms()
        u.drop = SIMD2(0.5, asp * Float(DROP_Y))
        switch m.connector.seamSide {
        case .left: u.seam = SIMD2(0, asp / 2)
        case .right: u.seam = SIMD2(1, asp / 2)
        case .top: u.seam = SIMD2(0.5, 0)
        case .bottom: u.seam = SIMD2(0.5, asp)
        }
        u.dropR = Float(DROP_R); u.fill = fill; u.jelly = jelly; u.time = Float(now - t0)
        u.front = burst < 0 ? -1 : frontMm(burst) / mmW
        u.fade = 1 - smooth(0.45, 0.95, burst)
        u.men = link * lensMm(fill) / mmW * (burst < 0 ? 1 : exp(-burst / 0.08))
        field.draw(pair: u)
    }

    private func fire(_ now: CFTimeInterval, _ m: AppModel) {
        // both screens start the wave at once: the Mac when "burst" reaches it, we that long after sending it
        let lead = min(m.client.pairRtt / 2, 0.3)
        firedAt = now + lead
        bursting = true
        m.client.sendJson(["t": "pair", "state": "burst", "p": 1])
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + lead + 0.12) { self.onOpen?() }
        DispatchQueue.main.asyncAfter(deadline: .now() + lead + 1.12) { self.onDone?() }
    }
}

private struct PairField: UIViewRepresentable {
    let view: FxView
    func makeUIView(context: Context) -> FxView { view }
    func updateUIView(_ v: FxView, context: Context) {}
}

struct PairGate: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var connector: Connector
    let onOpen: () -> Void
    let onDone: () -> Void
    @StateObject private var d = PairDriver()
    @State private var last = prefs.string(forKey: "lastName")
    @State private var askCode = false
    @State private var code = ""

    private var choosing: Bool { connector.found.count > 1 && !connector.found.contains { $0.name == last } }
    private var name: String? {
        if case .up(let m) = model.conn { return m }
        return choosing ? nil : last ?? connector.found.first?.name
    }
    private var caption: String {
        if d.denied { return "Not allowed. Tap to ask again" }
        if d.failed { return "Open lidrop on your computer" }
        if choosing { return "Choose your computer" }
        if case .connecting = model.conn { return "Click Allow on your computer" }
        return connector.found.isEmpty ? "Looking for your computer" : "Click Allow on your computer"
    }

    var body: some View {
        // proportional to the screen, with the drop in the lower half, where the thumb rests on any iPhone
        GeometryReader { g in
            let w = g.size.width, h = g.size.height, r = w * DROP_R
            ZStack {
                PairField(view: d.field)
                Group {
                    if d.bursting { EmptyView() } else if let name {
                        Text(name).font(.system(size: 26, weight: .semibold)).foregroundStyle(.white).lineLimit(2).minimumScaleFactor(0.7)
                            .multilineTextAlignment(.center).padding(.horizontal, 32)
                    } else if choosing {
                        HStack(spacing: 8) {
                            ForEach(connector.found) { f in
                                Button { prefs.set(f.name, forKey: "lastName"); last = f.name } label: {
                                    Text(f.name).font(.subheadline).lineLimit(1).padding(.horizontal, 14).frame(minHeight: 40)
                                        .background(.white.opacity(0.12), in: Capsule())
                                }
                                .foregroundStyle(.white)
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                }
                .position(x: w / 2, y: h * 0.26)
                Color.clear
                    .frame(width: r * 2, height: r * 2)
                    .contentShape(Circle())
                    .onTapGesture { d.retry() }
                    .accessibilityLabel(caption)
                    .position(x: w / 2, y: h * DROP_Y)
                Text(caption).font(.footnote).foregroundStyle(.white.opacity(d.bursting ? 0 : 0.55))
                    .position(x: w / 2, y: h * DROP_Y + r * 1.2 + 26)
                if d.failed {
                    Button("Use pairing code") { askCode = true }.font(.footnote).foregroundStyle(.white.opacity(0.55))
                        .frame(minHeight: 44).position(x: w / 2, y: h - 60)
                }
            }
            .allowsHitTesting(!d.bursting)   // what is under the dissolving wave is already usable
        }
        .alert("Pairing code or Mac IP", isPresented: $askCode) {
            TextField("Paste it here", text: $code).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Connect") { d.usePairingCode(code) }
        }
        .onAppear {
            d.model = model; d.onOpen = onOpen; d.onDone = onDone
            d.start()
        }
        .onDisappear { d.stop() }
    }
}

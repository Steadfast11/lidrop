import Foundation
import Network

struct Found: Identifiable, Hashable {
    let name: String
    let endpoint: NWEndpoint
    var id: String { name }
}

/// Finds Macs advertising `_lidrop._tcp` (NWBrowser), picks one (last-used, else the only one, else the user taps)
/// and reconnects whenever the link is down, over the tunnel when there is a ticket. Main thread only.
final class Connector: ObservableObject {
    @Published var found: [Found] = []
    @Published var target: String?
    unowned let model: AppModel
    private var browser: NWBrowser?
    private var fixedHost: String?
    private var foreground = false
    private var timer: Timer?
    private var viaTunnel = false
    private var tunnelTries = 0
    private var failTicks = 0

    var lastName: String? { prefs.string(forKey: "lastName") }

    init(model: AppModel) {
        self.model = model
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            if self?.foreground == true { self?.evaluate() }
        }
    }

    func onForeground() { foreground = true; stopDiscovery(); startDiscovery(); evaluate() }
    func onBackground() { foreground = false; stopDiscovery() }

    /// Asks the computer again after it said no.
    func retry() { model.client.disconnect() }

    /// The phone's edge that faces the Mac, the opposite of the Mac edge it last told us.
    var seamSide: Side {
        switch Seam.macEdge ?? prefs.string(forKey: "edge") {
        case "left": return .right
        case "top": return .bottom
        case "bottom": return .top
        default: return .left
        }
    }

    func connectManual(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("endpoint") { fixedHost = nil; model.client.saveTicket(t); return }   // Mac's "Copy pairing code"
        fixedHost = t
        target = t
        prefs.set(t, forKey: "ip")
        dial(t)
    }

    func noteConnected() {
        tunnelTries = 0
        if fixedHost == nil, let t = target { prefs.set(t, forKey: "lastName") }
    }

    /// The first pairing arrives over the LAN: move to the tunnel at once, it is the faster path.
    func noteTicket() {
        if model.conn.isUp && !viaTunnel && fixedHost == nil { model.client.disconnect() }
    }

    private func dial(_ t: String) {
        var host = t, port = DEFAULT_PORT
        if t.filter({ $0 == ":" }).count == 1, let i = t.lastIndex(of: ":") {
            host = String(t[..<i]); port = UInt16(t[t.index(after: i)...]) ?? DEFAULT_PORT
        }
        model.client.connect(host: host, port: port)
    }

    private func evaluate() {
        switch model.conn { case .up, .connecting: failTicks = 0; return; default: break }
        if model.conn == .failed(DENIED) { return }   // asking again now would put the same question straight back on the computer
        // link is down: retry every tick; every ~3 s also restart the browser so a Mac that came back is found again
        failTicks += 1
        if failTicks % 4 == 0 { stopDiscovery(clear: false); startDiscovery() }
        viaTunnel = false
        if let h = fixedHost { dial(h); return }
        let last = lastName
        let pick = found.first(where: { $0.name == last }) ?? (found.count == 1 ? found.first : nil)
        // the tunnel is preferred everywhere; the plain LAN path only covers a same-Wi-Fi network with no internet
        if let ticket = model.client.ticket, pick == nil || tunnelTries % 6 < 4, let port = Tunnel.up(ticket) {
            tunnelTries += 1
            viaTunnel = true
            if let last { target = last }
            model.client.connect(host: "127.0.0.1", port: port)
            return
        }
        tunnelTries += 1
        guard let pick else { return }
        target = pick.name
        model.client.connect(pick.endpoint)
    }

    private func startDiscovery() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: "_lidrop._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            var seen = Set<String>(), list: [Found] = []
            for r in results {
                if case let .service(name, _, _, _) = r.endpoint, seen.insert(name).inserted { list.append(Found(name: name, endpoint: r.endpoint)) }
            }
            DispatchQueue.main.async { self?.found = list.sorted { $0.name < $1.name } }
        }
        b.stateUpdateHandler = { [weak self] st in
            if case .failed = st {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.stopDiscovery(); if self?.foreground == true { self?.startDiscovery() } }
            }
        }
        browser = b
        b.start(queue: .main)
    }

    private func stopDiscovery(clear: Bool = true) {
        browser?.cancel(); browser = nil
        if clear { found = [] }
    }
}

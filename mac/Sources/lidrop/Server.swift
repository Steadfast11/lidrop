import AppKit
import Network

/// One connected phone: own buffer and transfer state.
final class Phone {
    let conn: NWConnection
    var name = "phone"
    var id: String?              // set once the phone is allowed; nothing else is accepted before that
    var role = "main"            // the app and its Share window are separate connections from one phone
    let connectedAt = Date()
    var buf = Data()
    var off = 0   // consumed prefix of buf, compacted once per receive (avoids O(n²) copying)

    // current phone → Mac drag
    var curID: String?
    var names: [String] = ["file"]
    var count = 1
    var committed = false
    var tmpURL: URL?
    var handle: FileHandle?
    var savedURLs: [URL] = []
    var thumb: NSImage?
    var stream: StreamFile?      // a video that can be watched while it arrives
    var streamDest: URL?
    weak var card: ShelfCard?

    // drag_move arrival stats, printed at drag_end (finds network/phone jitter)
    var moveCount = 0, slowGaps = 0
    var maxGapMs = 0.0
    var lastMoveAt = CACurrentMediaTime()

    init(_ c: NWConnection) { conn = c }

    /// Thread-safe (NWConnection.send may be called from any queue).
    func sendFrame(type: UInt8, payload: Data, done: (() -> Void)? = nil) {
        var f = Data()
        var len = UInt32(payload.count + 1).bigEndian
        withUnsafeBytes(of: &len) { f.append(contentsOf: $0) }
        f.append(type)
        f.append(payload)
        conn.send(content: f, completion: .contentProcessed { _ in done?() })
    }

    func send(_ o: [String: Any]) {
        guard let j = try? JSONSerialization.data(withJSONObject: o) else { return }
        sendFrame(type: 1, payload: j)
    }
}

/// TCP listener + PROTOCOL.md framing. Everything runs on the main queue (file writes on ioQueue).
final class Server {
    static let saveDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads/lidrop", isDirectory: true)

    let overlay: OverlayController
    let onPhones: ([String]) -> Void
    var listener: NWListener?
    var phones: [Phone] = []
    var dragOwner: Phone?        // phone whose phone→Mac drag is running
    var macDragActive = false    // a Mac→phone drag is running (set by MacDrag)
    var lastStarter: Phone?      // phone with the most recent drag_start
    var shelf: Shelf?            // received items stay on the desktop as floating cards
    let ioQueue = DispatchQueue(label: "lidrop.io")   // file writes stay off the main (animation) thread

    var busy: Bool { dragOwner != nil || macDragActive }

    /// Mac → phone target: most recent drag_start, else most recently connected.
    var target: Phone? {
        if let p = lastStarter, phones.contains(where: { $0 === p }) { return p }
        return phones.filter { $0.id != nil }.max(by: { $0.connectedAt < $1.connectedAt })
    }

    let trust = Trust()
    let tunnel = Tunnel(port: 7777)
    private var asking: Set<String> = []

    init(overlay: OverlayController, onPhones: @escaping ([String]) -> Void) {
        self.overlay = overlay
        self.onPhones = onPhones
    }

    func start() {
        do {
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let l = try NWListener(using: NWParameters(tls: nil, tcp: tcp), on: 7777)
            l.service = NWListener.Service(name: Host.current().localizedName ?? "Mac", type: "_lidrop._tcp")
            l.serviceRegistrationUpdateHandler = { print("bonjour:", $0) }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { print("listener:", $0) }
            l.start(queue: .main)
            listener = l
        } catch {
            print("listen failed:", error)
        }
        tunnel.onTicket = { [weak self] t in
            self?.phones.filter { $0.id != nil }.forEach { $0.send(["t": "ticket", "ticket": t]) }
        }
        tunnel.start()
    }

    /// `hello`: a remembered phone goes straight in; a new one needs Allow once, then never again.
    func hello(_ m: [String: Any], from p: Phone) {
        p.name = (m["name"] as? String) ?? "phone"
        p.role = (m["role"] as? String) ?? "main"
        guard let id = m["id"] as? String, !id.isEmpty else { p.conn.cancel(); return }
        if trust.valid(id: id, token: (m["token"] as? String) ?? "") { admit(p, id: id, token: nil); return }
        guard asking.insert(id).inserted else { p.conn.cancel(); return }
        DispatchQueue.main.async { [weak self, weak p] in
            guard let self, let p else { return }
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Allow \(p.name) to connect?"
            a.informativeText = "It will be remembered, and lidrop will connect to it automatically."
            a.addButton(withTitle: "Allow")
            a.addButton(withTitle: "Don't Allow")
            let ok = a.runModal() == .alertFirstButtonReturn
            self.asking.remove(id)
            guard self.phones.contains(where: { $0 === p }) else { return }
            if ok { self.admit(p, id: id, token: self.trust.allow(id: id)) }
            else { p.send(["t": "denied"]); p.conn.cancel() }
        }
    }

    private func admit(_ p: Phone, id: String, token: String?) {
        for o in phones where o !== p && o.id == id && o.role == p.role { o.conn.cancel() }   // the same window on a newer path
        p.id = id
        var w: [String: Any] = ["t": "welcome", "name": Host.current().localizedName ?? "Mac"]
        if let mm = overlay.mainScreenMm() { w["screen_mm"] = [mm.w, mm.h] }   // the phone sizes its half of the dome to this
        w["edge"] = UserDefaults.standard.string(forKey: "learnedEdge") ?? "right"   // where the seam is, for the ceremony
        if let token { w["token"] = token }
        if let t = tunnel.ticket { w["ticket"] = t }
        p.send(w)
        print("hello from", p.name)
        notifyPhones()
    }

    func accept(_ c: NWConnection) {
        let p = Phone(c)
        phones.append(p)
        c.stateUpdateHandler = { [weak self, weak p] st in
            guard let self, let p else { return }
            switch st {
            case .failed, .cancelled: self.drop(p)
            default: break
            }
        }
        c.start(queue: .main)
        receive(p)
    }

    func drop(_ p: Phone) {
        guard phones.contains(where: { $0 === p }) else { return }
        phones.removeAll { $0 === p }
        if dragOwner === p { overlay.cancel(); dragOwner = nil }
        abortTransfer(p)
        notifyPhones()
        print("phone disconnected:", p.name)
    }

    func notifyPhones() {
        var seen = Set<String>()
        onPhones(phones.filter { $0.id != nil && seen.insert($0.id!).inserted }.map { $0.name })
    }

    func receive(_ p: Phone) {
        p.conn.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self, weak p] data, _, done, err in
            guard let self, let p, self.phones.contains(where: { $0 === p }) else { return }
            if let data { p.buf.append(data); self.parse(p) }
            if done || err != nil {
                p.conn.cancel()
                return
            }
            self.receive(p)
        }
    }

    func parse(_ p: Phone) {
        while p.buf.count - p.off >= 4 {
            let s = p.buf.startIndex + p.off
            let n = Int(p.buf[s]) << 24 | Int(p.buf[s + 1]) << 16 | Int(p.buf[s + 2]) << 8 | Int(p.buf[s + 3])
            guard n >= 1 else { p.buf.removeAll(); p.off = 0; return }
            if p.buf.count - p.off < 4 + n { break }
            let type = p.buf[s + 4]
            let payload = p.buf.subdata(in: (s + 5)..<(s + 4 + n))
            p.off += 4 + n
            if type == 1 {
                if let o = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] { handle(o, from: p) }
            } else if type == 2, let h = p.handle {
                ioQueue.async { try? h.write(contentsOf: payload) }
            } else if type == 3, let st = p.stream {
                ioQueue.async { st.write(payload) }
            }
        }
        if p.off > 0 {
            p.buf.removeSubrange(p.buf.startIndex..<(p.buf.startIndex + p.off))
            p.off = 0
        }
    }

    func handle(_ m: [String: Any], from p: Phone) {
        if m["t"] as? String == "hello" { if p.id == nil { hello(m, from: p) }; return }
        guard p.id != nil else { return }
        let id = m["id"] as? String
        switch m["t"] as? String {
        case "saved", "error":
            print("phone says:", m)
        case "pair":
            let state = m["state"] as? String
            if state == "ping" { p.send(["t": "pair", "state": "pong"]); return }   // the phone times the link to start the wave with us
            guard !busy else { return }
            switch state {
            case "hold": overlay.pair(hold: (m["p"] as? NSNumber)?.doubleValue ?? 0)
            case "burst": overlay.pairBurst()
            default: overlay.pairCancel()
            }
        case "drag_start":
            if (dragOwner != nil && dragOwner !== p) || macDragActive {
                p.send(["t": "error", "id": id ?? NSNull(), "msg": "busy"])
                return
            }
            abortTransfer(p)
            dragOwner = p
            lastStarter = p
            p.curID = id
            p.committed = false
            p.savedURLs = []
            if let fs = m["files"] as? [[String: Any]], !fs.isEmpty {
                p.names = fs.map { ($0["name"] as? String) ?? "file" }
                p.count = max((m["count"] as? Int) ?? fs.count, 1)
            } else {
                p.names = [(m["name"] as? String) ?? "file"]
                p.count = 1
            }
            var img: NSImage?
            if let b = m["thumb"] as? String, let d = Data(base64Encoded: b) { img = NSImage(data: d) }
            var phoneMm: (w: Double, h: Double)?
            if let a = m["screen_mm"] as? [NSNumber], a.count == 2 { phoneMm = (a[0].doubleValue, a[1].doubleValue) }
            p.thumb = img
            overlay.dragStart(image: img, tileDp: (m["tile_dp"] as? NSNumber)?.doubleValue ?? 96,
                              tileMm: (m["tile_mm"] as? NSNumber)?.doubleValue, phoneMm: phoneMm, count: p.count)
            p.moveCount = 0; p.maxGapMs = 0; p.slowGaps = 0; p.lastMoveAt = CACurrentMediaTime()
        case "drag_move":
            guard id == p.curID, dragOwner === p else { return }
            let nowT = CACurrentMediaTime()
            let gap = (nowT - p.lastMoveAt) * 1000
            p.lastMoveAt = nowT
            p.moveCount += 1
            if p.moveCount > 1 { p.maxGapMs = max(p.maxGapMs, gap); if gap > 40 { p.slowGaps += 1 } }
            let o = (m["overhang"] as? NSNumber)?.doubleValue ?? 0
            let a = (m["along"] as? NSNumber)?.doubleValue ?? 0.5
            overlay.dragMove(phoneEdge: (m["edge"] as? String) ?? "left", overhang: o, along: a)
        case "drag_end":
            guard id == p.curID, dragOwner === p else { return }
            print(String(format: "drag stats: moves=%d maxGap=%.0fms gaps>40ms=%d", p.moveCount, p.maxGapMs, p.slowGaps))
            if (m["commit"] as? Bool) == true {
                p.committed = true
                overlay.settle()
            } else {
                overlay.retract()
                p.curID = nil
                dragOwner = nil
            }
        case "file_begin":
            guard id == p.curID, p.committed else { return }
            try? FileManager.default.createDirectory(at: Server.saveDir, withIntermediateDirectories: true)
            let t = Server.saveDir.appendingPathComponent(".partial-\(UUID().uuidString)")
            FileManager.default.createFile(atPath: t.path, contents: nil)
            p.tmpURL = t
            if (m["stream"] as? Bool) == true, let size = (m["size"] as? NSNumber)?.int64Value, size > 0 {
                beginStream(p, size: size, mime: m["mime"] as? String, tmp: t, id: id ?? "")
                return
            }
            p.handle = try? FileHandle(forWritingTo: t)
        case "file_end":
            guard id == p.curID, let t = p.tmpURL else { return }
            if p.stream != nil { endStream(p, tmp: t, id: id ?? ""); return }
            let index = (m["index"] as? Int) ?? 0
            let h = p.handle
            p.handle = nil
            p.tmpURL = nil
            let name = index < p.names.count ? p.names[index] : p.names[0]
            ioQueue.async { [weak self] in   // runs after every queued chunk write
                try? h?.close()
                DispatchQueue.main.async { self?.finishFile(p, tmp: t, name: name, index: index, id: id ?? "") }
            }
        default: break
        }
    }

    func finishFile(_ p: Phone, tmp: URL, name: String, index: Int, id: String) {
        guard id == p.curID else { try? FileManager.default.removeItem(at: tmp); return }
        let dest = uniqueURL(for: name)
        do {
            try FileManager.default.moveItem(at: tmp, to: dest)
            p.send(["t": "saved", "id": id, "index": index, "path": dest.path])
            p.savedURLs.append(dest)
            print("saved", dest.path)
            if p.savedURLs.count >= p.count || index >= p.count - 1 {
                // no Finder activation here (it would pull the user out of a full-screen app mid-burst):
                // the item stays as a floating card on the shelf; clicking the card reveals it.
                shelf?.add(urls: p.savedURLs, image: p.thumb, delay: overlay.landingDelay + 0.1)
                overlay.land()
                p.curID = nil
                if dragOwner === p { dragOwner = nil }
            }
        } catch {
            p.send(["t": "error", "id": id, "index": index, "msg": "\(error)"])
            overlay.retract()
            p.curID = nil
            if dragOwner === p { dragOwner = nil }
        }
    }

    /// The card lands at once and can be played; the file keeps arriving behind it.
    private func beginStream(_ p: Phone, size: Int64, mime: String?, tmp: URL, id: String) {
        guard let st = StreamFile(url: tmp, size: size, mime: mime) else {
            p.send(["t": "error", "id": id, "msg": "cannot open file"])
            return
        }
        let name = p.names[0]
        st.onWant = { [weak p] b in p?.send(["t": "want", "id": id, "block": b]) }
        p.stream = st
        p.streamDest = uniqueURL(for: name)
        shelf?.add(urls: [p.streamDest!], image: p.thumb, delay: overlay.landingDelay + 0.1) { Player.show(st, title: name) }
        let card = shelf?.cards.last
        p.card = card
        st.onProgress = { [weak card] f in DispatchQueue.main.async { card?.setProgress(f) } }
        overlay.land()
        if ProcessInfo.processInfo.environment["LIDROP_DEBUG_STREAM"] != nil { Player.show(st, title: name) }
    }

    private func endStream(_ p: Phone, tmp: URL, id: String) {
        guard let st = p.stream, let dest = p.streamDest else { return }
        ioQueue.async { [weak self] in   // runs after every queued block write
            let done = st.complete
            st.finishWriting()
            DispatchQueue.main.async {
                guard let self, id == p.curID else { return }
                p.stream = nil
                p.tmpURL = nil
                p.curID = nil
                if self.dragOwner === p { self.dragOwner = nil }
                do {
                    guard done else { throw CocoaError(.fileReadCorruptFile) }
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    p.send(["t": "saved", "id": id, "index": 0, "path": dest.path])
                    p.card?.finished()
                    print("saved", dest.path)
                } catch {
                    st.fail()
                    try? FileManager.default.removeItem(at: tmp)
                    p.send(["t": "error", "id": id, "index": 0, "msg": "\(error)"])
                    p.card?.dismiss()
                }
            }
        }
    }

    func abortTransfer(_ p: Phone) {
        if let st = p.stream { st.fail(); p.stream = nil; p.card?.dismiss() }
        let h = p.handle, t = p.tmpURL
        p.handle = nil
        p.tmpURL = nil
        p.curID = nil
        ioQueue.async {
            try? h?.close()
            if let t { try? FileManager.default.removeItem(at: t) }
        }
    }

    func uniqueURL(for name: String) -> URL {
        var base = (name as NSString).lastPathComponent
        if base.isEmpty || base.hasPrefix(".") { base = "file" + base }
        let ext = (base as NSString).pathExtension
        let stem = (base as NSString).deletingPathExtension
        var url = Server.saveDir.appendingPathComponent(base)
        var i = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = Server.saveDir.appendingPathComponent(ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)")
            i += 1
        }
        return url
    }
}

import UIKit

final class ActiveDrag {
    let items: [Item]
    let thumb: UIImage?
    let id = UUID().uuidString.lowercased()
    let startScale: CGFloat
    var item: Item { items[0] }
    var x: CGFloat = 0, y: CGFloat = 0
    var side: Side
    var overhang: CGFloat = 0
    var alongQ = 0, overhangQ = 0
    var started = false      // drag_start has been queued
    var finished = false     // finger lifted; final messages pending
    var commit = false
    var export: Task<URL, Error>?
    var lastMove: CFTimeInterval = 0, lastFx: CGFloat = 0, lastFy: CGFloat = 0
    var vx: CGFloat = 0, vy: CGFloat = 0   // finger speed, points/ms
    var flung = false, flightLeft = 24
    var f0 = CGPoint.zero   // where the finger picked it up
    init(items: [Item], thumb: UIImage?, scale: CGFloat, side: Side) { self.items = items; self.thumb = thumb; startScale = scale; self.side = side }
}

private let REACH: CGFloat = 1.8

private final class LinkProxy: NSObject {
    weak var c: DragController?
    @objc func tick() { c?.tick() }
}

final class DragController {
    unowned let model: AppModel
    let light = FxState()
    var overlay: OverlayView { model.overlay }
    private(set) var active: ActiveDrag?
    private(set) var linger: ActiveDrag?   // tile kept on screen for the burst after a committed drop
    private var pending: ActiveDrag?       // released, waiting for drag_start / final messages
    private var lastSide = Side.left
    private var link: CADisplayLink?
    private var lastA = -1, lastO = -1, lastS = ""
    private var expectSaved = 0, savedCount = 0

    init(model: AppModel) {
        self.model = model
        light.strong = false
    }

    /// The link dropped: abandon any drag / transfer in flight and say so instead of leaving "Sending…" up.
    func onLinkLost() {
        let wasSending = model.flags.sending
        if active != nil { active = nil; endLink(); overlay.endDrag() }
        pending = nil
        model.flags.dragging = false
        model.lifting = []
        model.setLifted()
        if light.running { fadeOutFx() }
        model.flags.sending = false
        expectSaved = 0
        model.pending = []
        if wasSending { model.showToast("Send failed", ms: 4000) }
    }

    func onSaved() {
        if expectSaved > 1 {
            savedCount += 1
            if savedCount >= expectSaved { expectSaved = 0; model.pending = [] }
        } else { expectSaved = 0; model.pending = [] }
    }

    func onError(_ msg: String) { model.pending = []; model.showToast("Mac: \(msg)") }

    func start(items: [Item], thumb: UIImage?, fx: CGFloat, fy: CGFloat, cell: CGFloat) {
        guard active == nil, pending == nil, !items.isEmpty else { return }
        if model.flags.sending { model.showToast("Still sending — wait for ✓"); return }
        if model.flags.receiving { model.showToast("Receiving from Mac…"); return }
        guard model.conn.isUp else { model.showToast("Open lidrop on your computer"); return }
        let a = ActiveDrag(items: items, thumb: thumb, scale: max(0.2, min(1, cell / TILE)), side: lastSide)
        a.f0 = CGPoint(x: fx, y: fy)
        active = a
        model.flags.dragging = true
        model.setLifted()
        lastA = -1; lastO = -1; lastS = ""
        linger = nil
        light.strong = false
        light.begin(lastSide)
        overlay.beginDrag(a)
        if items.count > 1 {
            model.lifting = Set(items.map(\.id))
            Task { [weak self] in
                var imgs: [UIImage] = []
                for it in items.dropFirst().prefix(2) { if let i = await it.thumbnail() { imgs.append(i) } }
                if self?.active === a { self?.overlay.dragTile.setFan(imgs) }
            }
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        move(fx, fy)
        let first = a.item
        a.export = Task.detached { try await first.export() }
        let sz = overlay.bounds.size, ns = overlay.window?.screen.nativeScale ?? 3
        Task { [weak self] in await self?.sendStart(a, sz, ns) }
        let p = LinkProxy(); p.c = self
        let l = CADisplayLink(target: p, selector: #selector(LinkProxy.tick))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func sendStart(_ a: ActiveDrag, _ b: CGSize, _ ns: CGFloat) async {
        // never hold drag_start back for a thumbnail: wait at most 150 ms
        var img = a.thumb
        if img == nil {
            img = await withTaskGroup(of: UIImage?.self) { g in
                g.addTask { await a.item.thumbnail() }
                g.addTask { try? await Task.sleep(nanoseconds: 150_000_000); return nil }
                let r = await g.next() ?? nil
                g.cancelAll()
                return r
            }
            if let img { await MainActor.run { self.overlay.setDragImage(img) } }
        }
        let th = img.flatMap { shapeThumb($0).jpegData(compressionQuality: 0.85) }?.base64EncodedString() ?? ""
        let j: [String: Any] = [
            "t": "drag_start", "id": a.id, "name": a.item.name, "mime": a.item.mime, "size": a.item.size,
            "thumb": th, "tile_dp": Int(TILE), "count": a.items.count,
            "files": a.items.map { ["name": $0.name, "size": $0.size, "mime": $0.mime] as [String: Any] },
            "tile_mm": pointsToMM(TILE, nativeScale: ns),
            "screen_mm": [pointsToMM(b.width, nativeScale: ns), pointsToMM(b.height, nativeScale: ns)],
        ]
        await MainActor.run {
            self.model.client.sendJson(j)
            a.started = true
        }
    }

    /// Same tileGeo as Drag.kt: near an edge the finger's anchor slides to the tile's trailing end so the tile leaves
    /// the screen (overhang 1 at distance e) while the finger stays on screen.
    func move(_ fx: CGFloat, _ fy: CGFloat) {
        guard let a = active else { return }
        // wherever it was picked up, the tile waits in the middle of the screen: from there every direction is as clear,
        // and the finger moves it relatively, a little faster, so an edge is in reach from any corner of the grid
        place(overlay.bounds.midX + (fx - a.f0.x) * REACH, overlay.bounds.midY + (fy - a.f0.y) * REACH)
    }

    private func place(_ fx: CGFloat, _ fy: CGFloat) {
        guard let a = active else { return }
        let now = CACurrentMediaTime() * 1000
        let gap = CGFloat(now - a.lastMove)
        if a.lastMove != 0 && gap > 0 {
            a.vx += ((fx - a.lastFx) / gap - a.vx) * 0.5
            a.vy += ((fy - a.lastFy) / gap - a.vy) * 0.5
        }
        a.lastFx = fx; a.lastFy = fy; a.lastMove = now
        let w = TILE, e = EDGE_SLACK, sw = overlay.bounds.width, sh = overlay.bounds.height
        let rx = min(2 * w, 0.45 * sw), ry = min(2 * w, 0.45 * sh)
        let k = w / 2 + e
        func cl(_ v: CGFloat) -> CGFloat { min(max(v, 0), 1) }
        let tl = cl((rx - fx) / (rx - e)), tr = cl((rx - (sw - fx)) / (rx - e))
        let tt = cl((ry - fy) / (ry - e)), tb = cl((ry - (sh - fy)) / (ry - e))
        let left = fx - (w / 2 + k * tl - k * tr)
        let top = fy - (w / 2 + k * tt - k * tb)
        let oL = cl(-left / w), oR = cl((left + w - sw) / w), oT = cl(-top / w), oB = cl((top + w - sh) / w)
        var best = Side.left, bv = oL
        if oR > bv { best = .right; bv = oR }
        if oT > bv { best = .top; bv = oT }
        if oB > bv { best = .bottom; bv = oB }
        let cur = a.side
        let cv: CGFloat = { switch cur { case .left: return oL; case .right: return oR; case .top: return oT; case .bottom: return oB } }()
        let side = (bv <= 0 || best == cur || bv < cv + 0.15) ? cur : best
        let ov: CGFloat = { switch side { case .left: return oL; case .right: return oR; case .top: return oT; case .bottom: return oB } }()
        let along = (side == .left || side == .right) ? fy / sh : fx / sw
        a.x = left; a.y = top; a.side = side; a.overhang = ov
        a.overhangQ = Int((ov * 10000).rounded())
        a.alongQ = Int((cl(along) * 10000).rounded())
        light.over(Float(ov)); light.along = Float(along)
        light.cx = Float(left + w / 2); light.cy = Float(top + w / 2)
        light.side = side
    }

    func end() {
        guard let a = active else { return }
        // a throw: the finger let go early but the tile is flying, so it carries on through the edge on its own
        if a.overhang < 0.5 && !a.flung && max(abs(a.vx), abs(a.vy)) > 0.4 { a.flung = true; return }
        finish(commit: true)
    }

    func cancel() { finish(commit: false) }

    private func finish(commit: Bool) {
        guard let a = active else { return }
        active = nil
        lastSide = a.side
        a.commit = commit && a.overhang >= 0.5
        a.finished = true
        pending = a
        model.lifting = []
        if a.commit {
            model.flags.sending = true
            linger = a
            model.pending = Set(a.items.map(\.id))
            let g = light.commit()
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(light.endMs())) { [weak self] in
                guard let self, self.light.stillCurrent(g) else { return }
                self.light.running = false
                self.linger = nil
                self.overlay.endDrag()
            }
        } else {
            overlay.endDrag()
            fadeOutFx()
        }
        model.setLifted()
    }

    private func fadeOutFx() {
        let g = light.cancel()
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(650)) { [weak self] in
            if let self, self.light.stillCurrent(g) { self.light.running = false }
        }
    }

    private func endLink() { link?.invalidate(); link = nil }

    fileprivate func tick() {
        if let a = active, a.flung {
            let now = CACurrentMediaTime() * 1000
            let dt = CGFloat(now - a.lastMove)
            let fx = a.lastFx + a.vx * dt, fy = a.lastFy + a.vy * dt, vx = a.vx, vy = a.vy
            place(fx, fy)
            a.vx = vx; a.vy = vy   // the flight keeps the speed of the throw
            a.flightLeft -= 1
            if a.overhang >= 0.6 || a.flightLeft <= 0 { finish(commit: true) }
        }
        guard let a = active ?? pending, a.started else { return }
        sendMoveIfChanged(a)
        guard a.finished else { return }
        // finger lifted and drag_start is out: final move, drag_end, then stream
        endLink()
        pending = nil
        lastA = -1
        _ = sendMoveIfChanged(a)
        model.client.sendJson(["t": "drag_end", "id": a.id, "commit": a.commit])
        model.flags.dragging = false
        if a.commit { stream(a) } else { let it = a.item, e = a.export; Task { if let u = try? await e?.value { it.cleanUp(u) } } }
    }

    @discardableResult
    private func sendMoveIfChanged(_ a: ActiveDrag) -> Bool {
        let al = a.alongQ, ov = a.overhangQ, sw = a.side.wire
        if al == lastA && ov == lastO && sw == lastS { return false }
        lastA = al; lastO = ov; lastS = sw
        model.client.sendRaw("{\"t\":\"drag_move\",\"id\":\"\(a.id)\",\"edge\":\"\(sw)\",\"along\":\(String(format: "%.4f", Double(al) / 10000)),\"overhang\":\(String(format: "%.4f", Double(ov) / 10000))}")
        return true
    }

    private func stream(_ a: ActiveDrag) {
        expectSaved = a.items.count; savedCount = 0
        let client = model.client, flags = model.flags, count = a.items.count
        Task.detached { [weak model] in
            defer { flags.sending = false }
            do {
                for (i, it) in a.items.enumerated() {
                    let url = try await (i == 0 ? a.export!.value : it.export())
                    defer { it.cleanUp(url) }
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? it.size
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        DispatchQueue.global(qos: .userInitiated).async {
                            do {
                                var begin: [String: Any] = ["t": "file_begin", "id": a.id, "index": i]
                                if count == 1 && it.isVideo && size > 0 {
                                    begin["stream"] = true; begin["size"] = size; begin["mime"] = it.mime
                                    client.sendJson(begin)
                                    try Self.sendBlocks(url, size: size, client: client, flags: flags)
                                } else {
                                    client.sendJson(begin)
                                    try Self.streamFile(url, client: client)
                                }
                                client.sendJson(["t": "file_end", "id": a.id, "index": i])
                                cont.resume()
                            } catch { cont.resume(throwing: error) }
                        }
                    }
                }
                let ids = Set(a.items.map(\.id))
                DispatchQueue.main.async { model?.tray.removeAll { ids.contains($0.id) } }
            } catch {
                // a dropped link is already reported by onLinkLost()
                if client.isUp { DispatchQueue.main.async { model?.showToast("Send failed: \(error.localizedDescription)") } }
            }
        }
    }

    private struct LinkLost: LocalizedError { var errorDescription: String? { "connection lost" } }

    private static func streamFile(_ url: URL, client: MacClient) throws {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let gate = DispatchSemaphore(value: 6)
        while true {
            guard client.isUp else { throw LinkLost() }
            let d = try fh.read(upToCount: CHUNK) ?? Data()
            if d.isEmpty { break }
            client.sendChunk(d, gate: gate)
        }
        for _ in 0..<6 { gate.wait() }   // drain: everything handed to the socket
        for _ in 0..<6 { gate.signal() }
    }

    /// A video goes as numbered blocks in file order, but the Mac's player can move the read position at any time
    /// ("want"): camera videos keep their index at the end, and seeking must not wait for the whole file.
    private static func sendBlocks(_ url: URL, size: Int64, client: MacClient, flags: Flags) throws {
        let count = Int((size + Int64(CHUNK) - 1) / Int64(CHUNK))
        var sent = [Bool](repeating: false, count: count)
        var left = count, next = 0
        _ = flags.takeWant()
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let gate = DispatchSemaphore(value: 6)
        while left > 0 {
            guard client.isUp else { throw LinkLost() }
            let w = flags.takeWant()
            if w >= 0 && w < count { next = w }
            while sent[next] { next = (next + 1) % count }
            try fh.seek(toOffset: UInt64(next) * UInt64(CHUNK))
            var n = UInt32(next).bigEndian
            var d = Data(bytes: &n, count: 4)
            d.append(try fh.read(upToCount: CHUNK) ?? Data())
            client.sendBlock(d, gate: gate)
            sent[next] = true
            left -= 1
            next = (next + 1) % count
        }
        for _ in 0..<6 { gate.wait() }
        for _ in 0..<6 { gate.signal() }
    }
}

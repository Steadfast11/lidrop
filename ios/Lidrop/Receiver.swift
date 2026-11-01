import UIKit

struct FileMeta { let name: String; let size: Int64 }

/// Mac → phone: runs on the network queue (file IO right here); UI work hops to main.
final class Receiver {
    unowned let model: AppModel
    let fx = FxState()
    private struct Inc {
        let id: String
        let files: [FileMeta]
        var committed = false
        var received: Int64 = 0      // bytes across all files
        var fileReceived: Int64 = 0
        var fh: FileHandle?
        var url: URL?
        var total: Int64 { files.reduce(0) { $0 + max($1.size, 0) } }
    }
    private var cur: Inc?
    private var ignoredId: String?

    init(model: AppModel) { self.model = model }

    private func opposite(_ macEdge: String) -> Side {
        switch macEdge { case "left": return .right; case "top": return .bottom; case "bottom": return .top; default: return .left }
    }

    private func parseFiles(_ j: [String: Any]) -> [FileMeta] {
        if let a = j["files"] as? [[String: Any]], !a.isEmpty {
            return a.map { FileMeta(name: $0["name"] as? String ?? "file", size: ($0["size"] as? NSNumber)?.int64Value ?? -1) }
        }
        return [FileMeta(name: j["name"] as? String ?? "file", size: (j["size"] as? NSNumber)?.int64Value ?? -1)]
    }

    func onJson(_ j: [String: Any]) {
        let id = j["id"] as? String ?? ""
        switch j["t"] as? String {
        case "mdrag_start":
            if model.flags.dragging || model.flags.sending || cur != nil { ignoredId = id; return }
            ignoredId = nil
            let img = (j["thumb"] as? String).flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }.flatMap { UIImage(data: $0) }
            let files = parseFiles(j)
            cur = Inc(id: id, files: files)
            model.flags.receiving = true
            let side = opposite(j["edge"] as? String ?? "right")
            DispatchQueue.main.async {
                self.model.setLifted()
                self.fx.strong = true
                self.fx.begin(side)
                self.model.overlay.showIncoming(img, count: files.count, side: side)
            }
        case "mdrag_move":
            guard cur?.id == id else { return }
            let d = CGFloat((j["overhang"] as? NSNumber)?.doubleValue ?? 0), a = CGFloat((j["along"] as? NSNumber)?.doubleValue ?? 0.5)
            let depth = min(max(d, 0), 1), along = min(max(a, 0), 1)
            DispatchQueue.main.async {
                let o = self.model.overlay
                o.updateIncoming(depth: depth, along: along)
                self.fx.over(Float(depth), line: 0.83); self.fx.along = Float(along)
                self.fx.placeEntering(o.inSide, Float(depth), Float(along), Float(o.bounds.width), Float(o.bounds.height), Float(TILE))
            }
        case "mdrag_end":
            guard cur?.id == id else { return }
            if j["commit"] as? Bool == true {
                cur?.committed = true
                let showBar = (cur?.total ?? 0) > 0
                DispatchQueue.main.async {
                    let o = self.model.overlay
                    self.fx.placeEntering(o.inSide, 1, Float(o.inAlong), Float(o.bounds.width), Float(o.bounds.height), Float(TILE))
                    let g = self.fx.commit()
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(self.fx.endMs())) { if self.fx.stillCurrent(g) { self.fx.running = false } }
                    o.animateIncoming(depth: 1, duration: 0.15)
                    if showBar { o.setIncomingProgress(0) }
                }
            } else {
                cur = nil
                model.flags.receiving = false
                DispatchQueue.main.async {
                    self.model.setLifted()
                    let g = self.fx.cancel()
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(650)) { if self.fx.stillCurrent(g) { self.fx.running = false } }
                    self.model.overlay.animateIncoming(depth: 0, duration: 0.16) { self.model.overlay.hideIncoming() }
                }
            }
        case "file_begin":
            if let c = cur, c.id == id, c.committed { open(index(j)) }
            else if id == ignoredId { model.client.sendJson(["t": "error", "id": id, "msg": "phone busy"]) }
        case "file_end":
            if cur?.id == id { finish(index(j)) }
        default: break
        }
    }

    private func index(_ j: [String: Any]) -> Int { (j["index"] as? NSNumber)?.intValue ?? 0 }

    func onChunk(_ d: Data) {
        guard var c = cur, let fh = c.fh else { return }
        do {
            try fh.write(contentsOf: d)
            c.fileReceived += Int64(d.count)
            c.received += Int64(d.count)
            cur = c
            if c.total > 0 {
                let p = Float(c.received) / Float(c.total)
                DispatchQueue.main.async { self.model.overlay.setIncomingProgress(p) }
            }
        } catch { fail(error.localizedDescription, 0) }
    }

    func onDown() {
        guard cur != nil else { return }
        abortFile()
        cur = nil
        model.flags.receiving = false
        DispatchQueue.main.async { self.model.setLifted(); self.fx.running = false; self.model.overlay.hideIncoming() }
    }

    /// The Mac gave up on what it was sending: the file is not coming, so the tile must not wait for it.
    func onMacError(_ id: String?) {
        guard let c = cur, id == nil || id == c.id else { return }
        abortFile()
        cur = nil
        model.flags.receiving = false
        DispatchQueue.main.async {
            self.model.setLifted()
            let g = self.fx.cancel()
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(650)) { if self.fx.stillCurrent(g) { self.fx.running = false } }
            self.model.overlay.animateIncoming(depth: 0, duration: 0.16) { self.model.overlay.hideIncoming() }
        }
    }

    private func uniqueURL(_ name: String) -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var safe = (name as NSString).lastPathComponent
        if safe.isEmpty || safe == "." || safe == ".." { safe = "file" }
        let base = (safe as NSString).deletingPathExtension, ext = (safe as NSString).pathExtension
        var u = dir.appendingPathComponent(safe), n = 0
        while FileManager.default.fileExists(atPath: u.path) {
            n += 1
            u = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
        }
        return u
    }

    private func open(_ index: Int) {
        guard var c = cur else { return }
        let meta = index < c.files.count ? c.files[index] : c.files[0]
        let u = uniqueURL(meta.name)
        guard FileManager.default.createFile(atPath: u.path, contents: nil), let fh = try? FileHandle(forWritingTo: u) else {
            return fail("cannot save", index)
        }
        c.fh = fh; c.url = u; c.fileReceived = 0
        cur = c
    }

    private func finish(_ index: Int) {
        guard var c = cur else { return }
        try? c.fh?.close()
        c.fh = nil
        cur = c
        let meta = index < c.files.count ? c.files[index] : c.files[0]
        if meta.size >= 0 && c.fileReceived != meta.size { return fail("size mismatch \(c.fileReceived)/\(meta.size)", index) }
        guard let u = c.url else { return fail("no file", index) }
        model.client.sendJson(["t": "saved", "id": c.id, "index": index, "path": u.path])
        c.url = nil
        cur = c
        DispatchQueue.main.async { self.model.receivedTick += 1 }
        if index >= c.files.count - 1 { done(c.files.count, u) }
    }

    private func done(_ count: Int, _ last: URL) {
        cur = nil
        model.flags.receiving = false
        DispatchQueue.main.async {
            self.model.setLifted()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            if count == 1 {
                self.model.showToast("Received ✓ \(last.lastPathComponent)", label: "Open", ms: 6000) { self.model.preview = last }
            } else {
                self.model.showToast("Received \(count) files ✓", label: "Show", ms: 6000) { self.model.showReceived = true }
            }
            self.model.overlay.fadeIncoming()
        }
    }

    private func abortFile() {
        try? cur?.fh?.close()
        if let u = cur?.url { try? FileManager.default.removeItem(at: u) }
    }

    private func fail(_ msg: String, _ index: Int) {
        let id = cur?.id
        abortFile()
        cur = nil
        model.flags.receiving = false
        if let id = id { model.client.sendJson(["t": "error", "id": id, "index": index, "msg": msg]) }
        DispatchQueue.main.async {
            self.model.setLifted()
            self.model.showToast("Receive failed: \(msg)")
            self.model.overlay.hideIncoming()
        }
    }
}

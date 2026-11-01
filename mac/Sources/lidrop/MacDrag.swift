import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Mac → phone: watches for a file drag (global mouse monitor + drag pasteboard) heading to the learned edge.
/// One regular file is sent as is; a folder or several files are sent as one zip (made on commit).
final class MacDrag {
    static let zone: CGFloat = 24
    static let commitDist: CGFloat = 4

    unowned let server: Server
    var monitor: Any?
    var downCount = 0
    var urls: [URL] = []
    var thumbB64: String?
    var thumbURL: URL?
    var active = false
    var id = ""
    var phone: Phone?

    init(server: Server) { self.server = server }

    func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] e in
            self?.handle(e)
        }
    }

    /// Mac edge that leads to the phone: entry edge of the last phone→Mac drag.
    var edge: String { UserDefaults.standard.string(forKey: "learnedEdge") ?? "right" }

    var asZip: Bool { urls.count > 1 || (urls.first.map(isDir) ?? false) }

    func isDir(_ u: URL) -> Bool { (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }

    func handle(_ e: NSEvent) {
        if ProcessInfo.processInfo.environment["LIDROP_DEBUG"] != nil { print("ev", e.type.rawValue, NSEvent.mouseLocation, server.phones.count, server.busy) }
        switch e.type {
        case .leftMouseDown:
            downCount = NSPasteboard(name: .drag).changeCount
            urls = []; thumbB64 = nil; thumbURL = nil
            active = false
        case .leftMouseDragged:
            drag()
        case .leftMouseUp:
            up()
        default: break
        }
    }

    /// (distance to edge in pt, along 0...1)
    func geometry() -> (CGFloat, Double) {
        let f = (NSScreen.main ?? NSScreen.screens[0]).frame
        let p = NSEvent.mouseLocation
        switch edge {
        case "left": return (p.x - f.minX, Double(1 - (p.y - f.minY) / f.height))
        case "top": return (f.maxY - p.y, Double((p.x - f.minX) / f.width))
        case "bottom": return (p.y - f.minY, Double((p.x - f.minX) / f.width))
        default: return (f.maxX - p.x, Double(1 - (p.y - f.minY) / f.height))
        }
    }

    func drag() {
        if !active { guard !server.busy, server.target != nil else { return } }
        if urls.isEmpty {
            let pb = NSPasteboard(name: .drag)
            guard pb.changeCount != downCount,
                  let us = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
                  !us.isEmpty
            else { return }
            urls = us
            if !asZip { prepareThumb(us[0]) }
        }
        let (dist, along) = geometry()
        let over = Double(min(max(1 - dist / MacDrag.zone, 0), 1))
        if !active {
            guard dist <= MacDrag.zone, let first = urls.first, let p = server.target, !server.busy else { return }
            active = true
            server.macDragActive = true
            phone = p
            id = UUID().uuidString
            let name = zipName(), zip = asZip
            let mime = zip ? "application/zip" : (UTType(filenameExtension: first.pathExtension)?.preferredMIMEType ?? "application/octet-stream")
            // the size of a zip is not known until commit; the phone skips its size check for -1
            let size = zip ? -1 : (try? first.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            p.send(["t": "mdrag_start", "id": id, "name": name, "mime": mime, "size": size,
                    "files": [["name": name, "size": size, "mime": mime]], "count": 1,
                    "thumb": zip ? zipThumb() : (thumbB64 ?? iconThumb(first)), "tile_mm": 35.5, "edge": edge])
            print("mdrag_start", name, "items:", urls.count, "to", p.name)
        }
        phone?.send(["t": "mdrag_move", "id": id, "along": min(max(along, 0), 1), "overhang": over])
        server.overlay.macGlow(edge: edge, overhang: over, along: along)
    }

    func up() {
        let was = active, p = phone, list = urls
        active = false; urls = []; phone = nil
        guard was, let p else { server.macDragActive = false; return }
        let commit = geometry().0 <= MacDrag.commitDist
        p.send(["t": "mdrag_end", "id": id, "commit": commit])
        server.overlay.macEnd(commit: commit)
        print("mdrag_end commit=\(commit)")
        if commit { stream(list, zip: list.count > 1 || isDir(list[0]), name: nameFor(list), to: p, id: id) }
        else { server.macDragActive = false }
    }

    func zipName() -> String { nameFor(urls) }

    func nameFor(_ us: [URL]) -> String {
        guard let first = us.first else { return "file" }
        if us.count > 1 { return "Archive.zip" }
        return isDir(first) ? first.lastPathComponent + ".zip" : first.lastPathComponent
    }

    // MARK: sending (background queue, bounded in-flight chunks)
    func stream(_ urls: [URL], zip: Bool, name: String, to p: Phone, id: String) {
        // macDragActive stays true until the transfer is over
        DispatchQueue.global(qos: .userInitiated).async { [server] in
            var tmpDir: URL?
            var file = urls[0]
            if zip {
                let t = FileManager.default.temporaryDirectory.appendingPathComponent("lidrop-\(UUID().uuidString)")
                tmpDir = t
                do {
                    file = try Self.makeZip(urls, name: name, in: t)
                } catch {
                    p.send(["t": "error", "id": id, "msg": "zip failed: \(error)"])
                    DispatchQueue.main.async { server.macDragActive = false }
                    try? FileManager.default.removeItem(at: t)
                    return
                }
            }
            defer {
                if let t = tmpDir { try? FileManager.default.removeItem(at: t) }
                DispatchQueue.main.async { server.macDragActive = false }
            }
            let h: FileHandle
            do { h = try FileHandle(forReadingFrom: file) } catch {
                print("cannot read", file.path, error)
                p.send(["t": "error", "id": id, "msg": "can't read this file"])
                let denied = (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSFileReadNoPermissionError
                if denied { DispatchQueue.main.async { Self.askForAccess(file) } }
                return
            }
            defer { try? h.close() }
            let sem = DispatchSemaphore(value: 6)
            p.send(["t": "file_begin", "id": id, "index": 0])
            while let chunk = try? h.read(upToCount: 256 * 1024), !chunk.isEmpty {
                sem.wait()
                p.sendFrame(type: 2, payload: chunk) { sem.signal() }
            }
            p.send(["t": "file_end", "id": id, "index": 0])
            print("streamed", name)
        }
    }

    /// macOS keeps Desktop, Documents and Downloads from apps until the user allows them.
    static func askForAccess(_ file: URL) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "lidrop can't read \(file.lastPathComponent)"
        a.informativeText = "Allow lidrop to use this folder in System Settings → Privacy & Security → Files and Folders, then drag it again."
        a.addButton(withTitle: "Open Settings")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn, let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(u)
        }
    }

    /// Zip one folder (named after it) or several items (copied into an "Archive" folder) with ditto.
    static func makeZip(_ urls: [URL], name: String, in dir: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var src = urls[0]
        if urls.count > 1 {
            src = dir.appendingPathComponent("Archive", isDirectory: true)
            try fm.createDirectory(at: src, withIntermediateDirectories: true)
            for u in urls {
                var dest = src.appendingPathComponent(u.lastPathComponent)
                var i = 1
                while fm.fileExists(atPath: dest.path) {
                    dest = src.appendingPathComponent("\(i)-" + u.lastPathComponent); i += 1
                }
                try fm.copyItem(at: u, to: dest)   // APFS clone, cheap
            }
        }
        let zip = dir.appendingPathComponent(name)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", src.path, zip.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw NSError(domain: "ditto", code: Int(p.terminationStatus)) }
        return zip
    }

    // MARK: thumbnails
    func prepareThumb(_ u: URL) {
        thumbURL = u
        let req = QLThumbnailGenerator.Request(fileAt: u, size: CGSize(width: 512, height: 512), scale: 1,
                                               representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            guard let cg = rep?.cgImage, let b = squareJPEG(cg) else { return }
            DispatchQueue.main.async { if self?.thumbURL == u { self?.thumbB64 = b } }
        }
    }

    func iconThumb(_ u: URL) -> String {
        let img = NSWorkspace.shared.icon(forFile: u.path)
        var r = NSRect(x: 0, y: 0, width: 512, height: 512)
        guard let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil) else { return "" }
        return squareJPEG(cg) ?? ""
    }

    /// Folder / archive icon with a red count badge (number of dragged items, or items inside the folder).
    func zipThumb() -> String {
        let n: Int
        if urls.count > 1 { n = urls.count }
        else { n = (try? FileManager.default.contentsOfDirectory(atPath: urls[0].path).filter { !$0.hasPrefix(".") }.count) ?? 0 }
        let icon = urls.count == 1 ? NSWorkspace.shared.icon(forFile: urls[0].path)
                                   : NSWorkspace.shared.icon(for: .zip)
        let img = NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            icon.draw(in: rect.insetBy(dx: 40, dy: 40))
            if n > 0 {
                let d: CGFloat = 150
                let b = NSRect(x: rect.maxX - d - 10, y: rect.maxY - d - 10, width: d, height: d)
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: b).fill()
                let s = NSAttributedString(string: "\(n)", attributes: [
                    .font: NSFont.boldSystemFont(ofSize: n > 99 ? 70 : 90), .foregroundColor: NSColor.white])
                let sz = s.size()
                s.draw(at: NSPoint(x: b.midX - sz.width / 2, y: b.midY - sz.height / 2))
            }
            return true
        }
        var r = NSRect(x: 0, y: 0, width: 512, height: 512)
        guard let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil) else { return "" }
        return squareJPEG(cg) ?? ""
    }
}

/// Center-crop to square, scale to 512x512, JPEG, base64.
func squareJPEG(_ cg: CGImage) -> String? {
    let side = min(cg.width, cg.height)
    let crop = CGRect(x: (cg.width - side) / 2, y: (cg.height - side) / 2, width: side, height: side)
    guard let sq = cg.cropping(to: crop),
          let ctx = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
    ctx.interpolationQuality = .high
    ctx.draw(sq, in: CGRect(x: 0, y: 0, width: 512, height: 512))
    guard let out = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: out)
    return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])?.base64EncodedString()
}

import AppKit
import AVFoundation
import AVKit
import UniformTypeIdentifiers

/// A video arriving out of order: blocks land in a sparse file and the player reads it while it fills.
/// Asking for a block the phone has not sent moves the phone's read position there, so seeking is instant.
final class StreamFile: NSObject, AVAssetResourceLoaderDelegate {
    static let block = 256 * 1024

    let size: Int64
    let type: String
    var onWant: ((Int) -> Void)?
    var onProgress: ((Double) -> Void)?
    private let out: FileHandle
    private let inp: FileHandle
    private let lock = NSLock()
    private let readLock = NSLock()
    private var have: [Bool]
    private var left: Int
    private var dead = false
    private var shown = -1

    init?(url: URL, size: Int64, mime: String?) {
        guard let o = try? FileHandle(forWritingTo: url), let i = try? FileHandle(forReadingFrom: url),
              (try? o.truncate(atOffset: UInt64(size))) != nil else { return nil }
        out = o; inp = i
        self.size = size
        type = mime.flatMap { UTType(mimeType: $0)?.identifier } ?? UTType.movie.identifier
        let n = Int((size + Int64(StreamFile.block) - 1) / Int64(StreamFile.block))
        have = [Bool](repeating: false, count: n)
        left = n
    }

    /// One frame of type 3: u32 BE block index, then the bytes. Runs on the write queue.
    func write(_ d: Data) {
        guard d.count > 4 else { return }
        let b = d.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        guard b < have.count, (try? out.seek(toOffset: UInt64(b) * UInt64(StreamFile.block))) != nil,
              (try? out.write(contentsOf: d.dropFirst(4))) != nil else { return }
        lock.lock()
        if !have[b] { have[b] = true; left -= 1 }
        let pct = 100 - left * 100 / max(have.count, 1)
        let changed = pct != shown
        shown = pct
        lock.unlock()
        if changed { onProgress?(Double(pct) / 100) }
    }

    var complete: Bool { lock.lock(); defer { lock.unlock() }; return left == 0 }
    func fail() { lock.lock(); dead = true; lock.unlock() }
    func finishWriting() { try? out.close() }

    private func has(_ b: Int) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return dead ? nil : have[b]
    }

    func resourceLoader(_ l: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource r: AVAssetResourceLoadingRequest) -> Bool {
        if let info = r.contentInformationRequest {
            info.contentType = type
            info.contentLength = size
            info.isByteRangeAccessSupported = true
        }
        guard let dr = r.dataRequest else { r.finishLoading(); return true }
        DispatchQueue.global(qos: .userInitiated).async { self.serve(r, dr) }
        return true
    }

    private func serve(_ r: AVAssetResourceLoadingRequest, _ dr: AVAssetResourceLoadingDataRequest) {
        var off = dr.currentOffset
        let end = dr.requestsAllDataToEndOfResource ? size : min(dr.requestedOffset + Int64(dr.requestedLength), size)
        var asked = -1
        while off < end, !r.isCancelled {
            let b = Int(off / Int64(StreamFile.block))
            guard let ok = has(b) else { r.finishLoading(with: URLError(.networkConnectionLost)); return }
            guard ok else {
                if asked != b { asked = b; onWant?(b) }
                Thread.sleep(forTimeInterval: 0.02)
                continue
            }
            let n = Int(min(end - off, Int64(b + 1) * Int64(StreamFile.block) - off))
            readLock.lock()
            try? inp.seek(toOffset: UInt64(off))
            let d = try? inp.read(upToCount: n)
            readLock.unlock()
            guard let d, !d.isEmpty else { break }
            dr.respond(with: d)
            off += Int64(d.count)
        }
        if !r.isCancelled { r.finishLoading() }
    }
}

/// One window per video being watched; it keeps its stream alive after the file has finished arriving.
enum Player {
    private static var open: [(NSWindow, AVPlayer, StreamFile)] = []

    static func show(_ st: StreamFile, title: String) {
        if let w = open.first(where: { $0.2 === st })?.0 { NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); return }
        let asset = AVURLAsset(url: URL(string: "lidrop-stream://video/file")!)
        asset.resourceLoader.setDelegate(st, queue: DispatchQueue(label: "lidrop.player"))
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        let view = AVPlayerView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
        view.player = player
        let w = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = title
        w.contentView = view
        w.isReleasedWhenClosed = false
        w.center()
        open.append((w, player, st))
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            player.pause()
            open.removeAll { $0.0 === w }
            if let token { NotificationCenter.default.removeObserver(token) }
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        player.play()
        if ProcessInfo.processInfo.environment["LIDROP_DEBUG_STREAM"] != nil {
            let t0 = CACurrentMediaTime()
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
                guard let d = player.currentItem?.duration.seconds, d.isFinite else { return }
                print("stream seek to \(Int(d * 0.8))s of \(Int(d))s at +9s")
                player.seek(to: CMTime(seconds: d * 0.8, preferredTimescale: 600))
            }
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                let e = player.currentItem?.error
                print(String(format: "stream +%.0fs play=%.1fs rate=%.1f status=%d %@", CACurrentMediaTime() - t0, player.currentTime().seconds, player.rate, player.timeControlStatus.rawValue, e.map { "\($0)" } ?? ""))
            }
        }
    }
}

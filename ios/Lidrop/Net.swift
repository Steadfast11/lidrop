import Foundation
import Network
import UIKit

let DENIED = "Not allowed on the computer"

enum Conn: Equatable {
    case idle, connecting, up(String), failed(String)
    var isUp: Bool { if case .up = self { return true }; return false }
}

/// NWConnection client speaking docs/PROTOCOL.md framing: u32 BE len · u8 type · payload.
/// All mutable state lives on `q`; callbacks onJson/onChunk/onDown run on `q`, onState/onTicket/onSaved/onError on main.
final class MacClient {
    let q = DispatchQueue(label: "lidrop.net")
    let flags: Flags
    private let role: String
    private var conn: NWConnection?
    private var gen = 0
    private let lock = NSLock()
    private var up = false
    var onState: ((Conn) -> Void)?
    var onTicket: ((String) -> Void)?
    var onSaved: ((_ id: String, _ path: String, _ index: Int) -> Void)?
    var onError: ((_ id: String?, _ msg: String) -> Void)?
    var onJson: (([String: Any]) -> Void)?
    var onChunk: ((Data) -> Void)?
    var onDown: (() -> Void)?

    /// Stable across launches and shared with the Share extension: the Mac trusts this id once, then never asks again.
    private static let deviceId: String = {
        if let id = prefs.string(forKey: "id") { return id }
        let id = UUID().uuidString.lowercased()
        prefs.set(id, forKey: "id")
        return id
    }()

    var ticket: String? { prefs.string(forKey: "ticket") }
    var token: String { prefs.string(forKey: "token") ?? "" }

    var pingAt: CFTimeInterval = 0    // connect ceremony: when the last ping left
    private var rtt: CFTimeInterval = 0
    /// The fastest answer to a ping, in seconds. Safe from any thread.
    var pairRtt: CFTimeInterval { lock.lock(); defer { lock.unlock() }; return rtt }

    /// True while the Mac has welcomed this connection. Safe from any thread.
    var isUp: Bool { lock.lock(); defer { lock.unlock() }; return up }

    init(flags: Flags, role: String) { self.flags = flags; self.role = role }

    func saveTicket(_ t: String) {
        guard t != ticket else { return }
        prefs.set(t, forKey: "ticket")
        DispatchQueue.main.async { self.onTicket?(t) }
    }

    private func publish(_ c: Conn) {
        lock.lock(); up = c.isUp; lock.unlock()
        DispatchQueue.main.async { self.onState?(c) }
    }

    func connect(host: String, port: UInt16 = DEFAULT_PORT) {
        let p = NWEndpoint.Port(rawValue: port) ?? 7777
        connect(NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: p), tunnel: host == "127.0.0.1" && port != DEFAULT_PORT)
    }

    func connect(_ ep: NWEndpoint, tunnel: Bool = false) {
        q.async {
            self.teardown()
            self.gen += 1
            let g = self.gen
            self.publish(.connecting)
            let params = NWParameters.tcp
            if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcp.noDelay = true
                tcp.connectionTimeout = 4
            }
            let c = NWConnection(to: ep, using: params)
            self.conn = c
            c.stateUpdateHandler = { [weak self] st in self?.handle(st, c, g) }
            c.start(queue: self.q)
            // a tunnel whose far end is unreachable stays silent, and an address that stopped answering can stay "preparing"
            // for ever: give up on it rather than hang, the next tick dials again. A live link may be waiting for Allow.
            self.q.asyncAfter(deadline: .now() + (tunnel ? 12 : 6)) { [weak self] in
                guard let self, g == self.gen, self.conn === c, tunnel ? !self.isUp : c.state != .ready else { return }
                self.fail(c, g, "timed out")
            }
        }
    }

    func disconnect() {
        q.async {
            self.teardown()
            self.publish(.idle)
        }
    }

    private func teardown() {
        gen += 1
        let c = conn
        conn = nil
        c?.stateUpdateHandler = nil
        c?.cancel()
        onDown?()
    }

    private func fail(_ c: NWConnection, _ g: Int, _ msg: String) {
        guard g == gen else { return }
        conn = nil
        c.stateUpdateHandler = nil
        c.cancel()
        publish(.failed(msg))
        onDown?()
    }

    private func handle(_ st: NWConnection.State, _ c: NWConnection, _ g: Int) {
        guard g == gen else { return }
        switch st {
        case .ready:
            sendJson(["t": "hello", "name": UIDevice.current.name, "v": 0, "id": Self.deviceId, "role": role, "token": prefs.string(forKey: "token") ?? ""])
            readFrame(c, g)
        case .failed(let e): fail(c, g, e.localizedDescription)
        case .waiting(let e): fail(c, g, e.localizedDescription)
        default: break
        }
    }

    private func readFrame(_ c: NWConnection, _ g: Int) {
        c.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, err in
            guard let self = self, g == self.gen else { return }
            guard err == nil, let d = data, d.count == 4 else { return self.fail(c, g, "Mac closed the connection") }
            let len = Int(d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian)
            guard len >= 1, len <= 32 << 20 else { return self.fail(c, g, "bad frame") }
            c.receive(minimumIncompleteLength: len, maximumLength: len) { [weak self] body, _, _, err in
                guard let self = self, g == self.gen else { return }
                guard err == nil, let b = body, b.count == len else { return self.fail(c, g, "Mac closed the connection") }
                let type = b[b.startIndex]
                let payload = b.subdata(in: (b.startIndex + 1)..<b.endIndex)
                if type == 1 {
                    if let j = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] {
                        if j["t"] as? String == "denied" { return self.fail(c, g, DENIED) }
                        self.control(j)
                    }
                } else { self.onChunk?(payload) }
                self.readFrame(c, g)
            }
        }
    }

    private func control(_ j: [String: Any]) {
        switch j["t"] as? String {
        case "welcome":
            if let mm = j["screen_mm"] as? [NSNumber], mm.count == 2 { Seam.macW = mm[0].floatValue; Seam.macH = mm[1].floatValue }
            if let t = j["token"] as? String, !t.isEmpty { prefs.set(t, forKey: "token") }
            if let e = j["edge"] as? String, !e.isEmpty { Seam.macEdge = e; prefs.set(e, forKey: "edge") }
            lock.lock(); rtt = 0; lock.unlock()
            publish(.up(j["name"] as? String ?? "Mac"))
            if let t = j["ticket"] as? String, !t.isEmpty { saveTicket(t) }
        case "ticket":
            if let t = j["ticket"] as? String, !t.isEmpty { saveTicket(t) }
        case "want":
            flags.setWant((j["block"] as? NSNumber)?.intValue ?? -1)
        case "pair":
            if j["state"] as? String == "pong" {
                let r = CACurrentMediaTime() - pingAt
                lock.lock(); if rtt == 0 || r < rtt { rtt = r }; lock.unlock()
            }
        case "saved":
            let id = j["id"] as? String ?? "", path = j["path"] as? String ?? "", i = (j["index"] as? NSNumber)?.intValue ?? 0
            DispatchQueue.main.async { self.onSaved?(id, path, i) }
        case "error":
            let id = (j["id"] as? String).flatMap { $0.isEmpty || $0 == "null" ? nil : $0 }, msg = j["msg"] as? String ?? "error"
            DispatchQueue.main.async { self.onError?(id, msg) }
        default: onJson?(j)
        }
    }

    func sendJson(_ o: [String: Any]) {
        if let d = try? JSONSerialization.data(withJSONObject: o) { send(1, d) }
    }

    func sendRaw(_ s: String) { send(1, Data(s.utf8)) }

    func send(_ type: UInt8, _ payload: Data, done: (() -> Void)? = nil) {
        var d = Data(capacity: payload.count + 5)
        var n = UInt32(payload.count + 1).bigEndian
        withUnsafeBytes(of: &n) { d.append(contentsOf: $0) }
        d.append(type)
        d.append(payload)
        q.async {
            guard let c = self.conn else { done?(); return }
            c.send(content: d, completion: .contentProcessed { _ in done?() })
        }
    }

    /// Blocks the calling (background) thread while more than `inflight` frames are queued.
    func sendChunk(_ payload: Data, gate: DispatchSemaphore) {
        gate.wait()
        send(2, payload) { gate.signal() }
    }

    func sendBlock(_ payload: Data, gate: DispatchSemaphore) {
        gate.wait()
        send(3, payload) { gate.signal() }
    }
}

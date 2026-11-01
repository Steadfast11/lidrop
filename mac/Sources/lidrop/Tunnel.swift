import Foundation
import Security

/// App data folder: the tunnel key and the phones the user allowed. Never expires.
enum Store {
    static let dir: URL = {
        let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/lidrop", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return d
    }()

    static func randomHex(_ n: Int) -> String {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return b.map { String(format: "%02x", $0) }.joined()
    }

    static func write(_ d: Data, to u: URL) {
        try? d.write(to: u, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u.path)
    }
}

/// Phones the user allowed: phone id → token handed out on Allow.
final class Trust {
    private let url = Store.dir.appendingPathComponent("trust.json")
    private var phones: [String: String]

    init() {
        phones = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
    }

    func valid(id: String, token: String) -> Bool { !token.isEmpty && phones[id] == token }

    func allow(id: String) -> String {
        let t = Store.randomHex(32)
        phones[id] = t
        if let d = try? JSONEncoder().encode(phones) { Store.write(d, to: url) }
        return t
    }
}

/// Runs the bundled iroh tunnel: internet-reachable, end-to-end encrypted, forwards to the local TCP port.
/// A stable key keeps the ticket stable, so a phone paired once can always find this Mac.
final class Tunnel {
    var onTicket: ((String) -> Void)?
    private(set) var ticket: String?
    private var proc: Process?
    private var stopping = false
    private let port: Int

    init(port: Int) { self.port = port }

    private var binary: URL? {
        let u = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("dumbpipe")
        return u.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    private func secret() -> String {
        let u = Store.dir.appendingPathComponent("tunnel.key")
        if let s = try? String(contentsOf: u, encoding: .utf8), s.count == 64 { return s }
        let s = Store.randomHex(32)
        Store.write(Data(s.utf8), to: u)
        return s
    }

    func start() {
        guard let binary else { print("tunnel: dumbpipe not bundled"); return }
        // a crashed or killed app leaves its tunnel behind; two listeners on one key steal each other's connections
        let old = Process()
        old.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        old.arguments = ["-f", "\(binary.path) listen-tcp"]
        try? old.run()
        old.waitUntilExit()
        let p = Process()
        p.executableURL = binary
        p.arguments = ["listen-tcp", "--host", "127.0.0.1:\(port)"]
        p.environment = ["IROH_SECRET": secret()]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self, let s = String(data: h.availableData, encoding: .utf8),
                  let r = s.range(of: "endpoint[a-z0-9]+", options: .regularExpression) else { return }
            let t = String(s[r])
            DispatchQueue.main.async {
                guard self.ticket != t else { return }
                self.ticket = t
                print("tunnel ready")
                self.onTicket?(t)
            }
        }
        p.terminationHandler = { [weak self] _ in
            out.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let self, !self.stopping else { return }
                self.start()
            }
        }
        do { try p.run(); proc = p } catch { print("tunnel:", error) }
    }

    func stop() {
        stopping = true
        proc?.terminate()
    }
}

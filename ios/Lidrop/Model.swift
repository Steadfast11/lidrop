import SwiftUI

struct Toast: Identifiable {
    let id = UUID()
    let text: String
    let label: String?
    let action: (() -> Void)?
}

/// One connection and everything hanging off it. The app runs one as "main"; the Share extension its own as "share".
final class AppModel: ObservableObject {
    @Published var conn: Conn = .idle
    @Published var toast: Toast?
    @Published var lifted = false               // a file is in the air: everything behind it softens and darkens
    @Published var tray: [Item] = []            // selection / share tray: dragging it sends all of these, in order
    @Published var pending = Set<String>()      // being sent: their cells show a dashed slot
    @Published var lifting = Set<String>()      // a group in the hand: its tiles have left the grid
    @Published var showReceived = false
    @Published var receivedTick = 0
    @Published var demoTick = 0                 // bumped to play the debug light demo
    @Published var preview: URL?
    @Published var paired = false               // a computer has allowed this phone: the gallery opens at once, for good
    @Published var gate = false                 // the first-pairing ceremony is on screen
    let flags = Flags()
    let client: MacClient
    let overlay = OverlayView()
    var drag: DragController!
    var receiver: Receiver?
    var connector: Connector!
    private var wasUp = false

    init(role: String = "main") {
        client = MacClient(flags: flags, role: role)
        paired = !client.token.isEmpty || UserDefaults.standard.bool(forKey: "skipGate")   // test hook: launch with `-skipGate YES`
        drag = DragController(model: self)
        if role == "main" { receiver = Receiver(model: self) }
        connector = Connector(model: self)
        overlay.attach(drag: drag, receiver: receiver)
        client.onState = { [weak self] c in
            guard let self = self else { return }
            self.conn = c
            if c.isUp { self.connector.noteConnected() }
            if self.wasUp && !c.isUp { self.drag.onLinkLost() }
            self.wasUp = c.isUp
            self.connector.objectWillChange.send()
        }
        client.onTicket = { [weak self] _ in self?.connector.noteTicket() }
        client.onSaved = { [weak self] _, _, _ in self?.drag.onSaved() }
        client.onError = { [weak self] id, msg in
            guard let self = self else { return }
            self.drag.onError(msg)
            self.client.q.async { self.receiver?.onMacError(id) }
        }
        client.onJson = { [weak self] j in self?.receiver?.onJson(j) }
        client.onChunk = { [weak self] d in self?.receiver?.onChunk(d) }
        client.onDown = { [weak self] in self?.receiver?.onDown() }
    }

    /// Going away on purpose: iOS is about to kill the sockets anyway, so nothing here is a lost link.
    func leave() {
        wasUp = false
        client.disconnect()
        Tunnel.down()
    }

    func setLifted() {
        let v = drag.active != nil || flags.receiving
        if v != lifted { lifted = v }
    }

    private var toastGen = 0
    func showToast(_ s: String, label: String? = nil, ms: Int = 2200, action: (() -> Void)? = nil) {
        toast = Toast(text: s, label: label, action: action)
        toastGen += 1
        let g = toastGen
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) { if g == self.toastGen { self.toast = nil } }
    }
}

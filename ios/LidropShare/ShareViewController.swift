import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Share target: a see-through screen over whatever app the file came from. The throw happens there, then it closes.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private let model = AppModel(role: "share")
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lidrop-share-\(UUID().uuidString)", isDirectory: true)

    override init(nibName: String?, bundle: Bundle?) {
        super.init(nibName: nibName, bundle: bundle)
        modalPresentationStyle = .overFullScreen
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        Looks.load()
        FxGPU.prepare()
        Task { @MainActor in
            let items = await loadItems()
            if items.isEmpty { return close() }
            model.tray = items
            let host = UIHostingController(rootView: ShareScreen(onDone: { [weak self] in self?.close() }).environmentObject(model))
            host.view.backgroundColor = .clear
            addChild(host)
            host.view.frame = view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(host.view)
            host.didMove(toParent: self)
            model.connector.onForeground()
        }
    }

    private func close() {
        model.connector.onBackground()
        model.leave()
        try? FileManager.default.removeItem(at: dir)
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func loadItems() async -> [Item] {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        var out: [Item] = []
        for (i, p) in providers.enumerated() {
            if let u = await copyFile(p, i) { out.append(Item.make(url: u)) }
        }
        return out
    }

    /// The system hands out each file only for the length of a callback: keep our own copy for the transfer.
    private func copyFile(_ p: NSItemProvider, _ index: Int) async -> URL? {
        guard let type = p.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .data) == true }) else { return nil }
        let dest = dir.appendingPathComponent("\(index)", isDirectory: true)
        return await withCheckedContinuation { cont in
            _ = p.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else { return cont.resume(returning: nil) }
                let name = p.suggestedName.map { n in (n as NSString).pathExtension.isEmpty && !url.pathExtension.isEmpty ? "\(n).\(url.pathExtension)" : n } ?? url.lastPathComponent
                let to = dest.appendingPathComponent(name)
                do {
                    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: to)
                    cont.resume(returning: to)
                } catch { cont.resume(returning: nil) }
            }
        }
    }
}

private struct Backdrop: UIViewRepresentable {
    func makeUIView(context: Context) -> UIVisualEffectView { UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark)) }
    func updateUIView(_ v: UIVisualEffectView, context: Context) {}
}

private struct ShareScreen: View {
    @EnvironmentObject var model: AppModel
    let onDone: () -> Void
    @State private var thumb: UIImage?
    @State private var sent = false

    var body: some View {
        // the source stays on screen while dragging, invisible: removing it would cancel the gesture it owns
        let busy = model.lifted || !model.pending.isEmpty
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                Backdrop().ignoresSafeArea()
                Color.black.opacity(0.45).ignoresSafeArea()
                // a little below the middle, under the thumb
                // the link comes up by itself; until it does the tile only waits, a little dimmer
                StackTile(thumb: thumb, count: model.tray.count)
                    .frame(width: min(TILE, w * 0.52), height: min(TILE, w * 0.52))
                    .overlay { DragSource(items: { model.tray }, thumb: { thumb }, instant: true) }
                    .opacity(busy ? 0 : model.conn.isUp ? 1 : 0.6)
                    .position(x: w / 2, y: h * 0.56)
                if !busy {
                    VStack {
                        Spacer()
                        Button(action: onDone) { Text("Cancel").frame(minWidth: 120, minHeight: 44) }
                            .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(.white).padding(.bottom, 12)
                    }
                }
                OverlayHost(view: model.overlay).ignoresSafeArea().allowsHitTesting(false)
            }
        }
        .task(id: model.tray.first?.id) { thumb = await model.tray.first?.thumbnail() }
        .onChange(of: model.pending) { _, p in
            if !p.isEmpty { sent = true }
            else if sent { DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: onDone) }
        }
    }
}

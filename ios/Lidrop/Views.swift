import SwiftUI
import Photos
import QuickLook
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var demo = false

    var body: some View {
        ZStack {
            Color.bg.ignoresSafeArea()
            if model.paired {
                // lifting a file softens and darkens everything behind it
                GalleryView().blur(radius: model.lifted ? 12 : 0)
            }
            Color.black.opacity(model.lifted ? 0.55 : 0).ignoresSafeArea().allowsHitTesting(false)
            if demo { LinearGradient(colors: [Color(red: 0.16, green: 0.78, blue: 0.9), Color(red: 0.1, green: 0.5, blue: 0.62), Color(red: 0.05, green: 0.17, blue: 0.24)], startPoint: .top, endPoint: .bottom).ignoresSafeArea() }
            OverlayHost(view: model.overlay).ignoresSafeArea().allowsHitTesting(false)
            if !model.paired || model.gate {
                PairGate(connector: model.connector, onOpen: { model.paired = true }, onDone: { model.gate = false })
                    .ignoresSafeArea()
                    .onAppear { model.gate = true }
            }
            if let t = model.toast {
                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        Text(t.text).foregroundStyle(.white).lineLimit(2)
                        if let l = t.label { Button(l) { t.action?() }.fontWeight(.semibold).foregroundStyle(Color.accent2).frame(minHeight: 44) }
                    }
                    .padding(.horizontal, 18).padding(.vertical, t.label == nil ? 12 : 2)
                    .background(Color(red: 0.13, green: 0.14, blue: 0.16).opacity(0.94), in: Capsule())
                    .padding(.horizontal, 16)
                    .padding(.bottom, toastInset)
                }
                .allowsHitTesting(t.label != nil)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: model.lifted ? 0.22 : 0.16), value: model.lifted)
        .animation(.easeOut(duration: 0.15), value: model.toast?.id)
        .persistentSystemOverlays(model.lifted ? .hidden : .automatic)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .quickLookPreview($model.preview)
        .onAppear { if UserDefaults.standard.bool(forKey: "fxdemo") { playDemo() } }
        .onChange(of: model.demoTick) { _, _ in playDemo() }
    }

    /// Above the bottom controls, where the thumb is not covering it.
    private var toastInset: CGFloat {
        guard model.paired else { return 128 }
        if model.tray.isEmpty { return 76 }
        return model.tray.contains { if case .file = $0.source { return true }; return false } ? 164 : 130
    }

    /// Debug: approach, hold and landing with no Mac attached, the same timeline as mac/tools/light_lab.swift.
    private func playDemo() {
        let fx = model.receiver?.fx ?? model.drag.light, o = model.overlay
        fx.strong = true
        fx.begin(.right)
        demo = true
        let t0 = CACurrentMediaTime()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { timer in
            let t = Float(CACurrentMediaTime() - t0)
            let over = t < 1.6 ? 0.8 * t / 1.6 : t < 2.6 ? 0.8 : 0.8 + (t - 2.6)
            fx.over(over); fx.along = 0.45
            fx.placeEntering(.right, over, 0.45, Float(o.bounds.width), Float(o.bounds.height), Float(TILE))
            if t >= 2.8 {
                timer.invalidate()
                let g = fx.commit()
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(fx.endMs())) {
                    if fx.stillCurrent(g) { fx.running = false }
                    demo = false
                }
            }
        }
    }
}

struct GalleryView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var connector: Connector
    @Environment(\.scenePhase) private var phase
    private var mac: String {
        if case .up(let m) = model.conn { return m }
        return connector.lastName ?? "Computer"
    }
    @State private var auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var fetch: PHFetchResult<PHAsset>?
    @State private var received: [RecvFile] = []
    @State private var trayThumb: UIImage?
    @State private var showPicker = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.showReceived {
                ReceivedList(files: received)
            } else if auth == .authorized || auth == .limited {
                ScrollView {
                    // two big tiles on every iPhone: easy to hit with a thumb, and they scale with the screen
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 260), spacing: 10)], spacing: 10) {
                        ForEach(0..<(fetch?.count ?? 0), id: \.self) { i in
                            if let a = fetch?.object(at: i) { AssetCell(asset: a).id(a.localIdentifier) }
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
                }
                .refreshable { reload() }
            } else {
                noAccess
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomControls }
        .foregroundStyle(.white)
        .onAppear { if auth == .notDetermined { ask() } else { reload() }; loadReceived() }
        .onChange(of: phase) { _, p in if p == .active { reload(); loadReceived() } }
        .onChange(of: model.receivedTick) { _, _ in loadReceived() }
        .onChange(of: model.showReceived) { _, _ in loadReceived() }
        .sheet(isPresented: $showPicker) {
            DocPicker { urls in if !urls.isEmpty { model.tray = urls.map(Item.make(url:)) } }
        }
    }

    /// The computer's name, and whether the link is up. There is nothing to do here: the link looks after itself.
    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Circle().fill(model.conn.isUp ? Color.green : Color.dimText).frame(width: 8, height: 8)
                Text(mac).font(.subheadline.weight(.medium)).lineLimit(1)
            }
            .padding(.horizontal, 14).frame(minHeight: 40)
            .background(.white.opacity(0.08), in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.conn.isUp ? "Connected to \(mac)" : "Connecting to \(mac)")
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
    }

    /// Everything the thumb needs, floating over the bottom of the grid.
    private var bottomControls: some View {
        VStack(spacing: 8) {
            // files picked with + are not in the grid, so they need a tile to hold; selected photos only need a way out
            if let first = model.tray.first {
                Group {
                    if model.tray.contains(where: { if case .file = $0.source { return true }; return false }) { trayCard(first) } else { selectionPill }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: 4) {
                dockTab("Photos", "photo.on.rectangle", on: !model.showReceived) { model.showReceived = false }
                dockTab("Received", "tray.and.arrow.down", on: model.showReceived) { model.showReceived = true }
                Button { showPicker = true } label: {
                    Image(systemName: "plus").font(.title3.weight(.semibold)).foregroundStyle(.white)
                        .frame(width: 48, height: 48).background(Color.accentColor, in: Circle())
                }
                .accessibilityLabel("Pick files")
            }
            .padding(5)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, Color.bg.opacity(0.9)], startPoint: .top, endPoint: .bottom).ignoresSafeArea().allowsHitTesting(false)
        }
        .animation(.spring(duration: 0.28), value: model.tray.isEmpty)
    }

    private var selectionPill: some View {
        Button { model.tray.removeAll() } label: {
            HStack(spacing: 6) {
                Text("\(model.tray.count) selected").font(.subheadline.weight(.medium))
                Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(Color.dimText)
            }
            .padding(.leading, 16).padding(.trailing, 12).frame(minHeight: 40)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .foregroundStyle(.white)
    }

    private func dockTab(_ title: String, _ icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.subheadline.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(on ? Color.white.opacity(0.16) : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .foregroundStyle(on ? Color.white : Color.dimText)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func trayCard(_ first: Item) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                StackTile(thumb: trayThumb, count: model.tray.count).frame(width: 60, height: 60)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.tray.count == 1 ? first.name : "\(model.tray.count) files").font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(humanSize(model.tray.reduce(0) { $0 + max($1.size, 0) })).font(.caption).foregroundStyle(Color.dimText).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .overlay { DragSource(items: { model.tray }, thumb: { trayThumb }) }
            Button { model.tray.removeAll() } label: {
                Image(systemName: "xmark").font(.subheadline.weight(.semibold)).foregroundStyle(Color.dimText)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Clear selection")
        }
        .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .task(id: first.id) { trayThumb = await first.thumbnail() }
    }

    private var noAccess: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled").font(.largeTitle).foregroundStyle(Color.dimText)
            Text(auth == .notDetermined ? "Allow access to your photos and videos" : "Photos access is off. Turn it on in Settings, or pick files with +")
                .multilineTextAlignment(.center)
            if auth == .notDetermined {
                Button("Allow photos & videos") { ask() }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
            } else if let u = URL(string: UIApplication.openSettingsURLString) {
                Button("Open Settings") { UIApplication.shared.open(u) }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
            }
            Spacer()
        }
        .padding(24)
    }

    private func ask() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { s in DispatchQueue.main.async { auth = s; reload() } }
    }

    private func reload() {
        guard auth == .authorized || auth == .limited else { return }
        let o = PHFetchOptions()
        o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        o.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        o.fetchLimit = 400
        // the first query can wait on the Photos daemon: never with the main thread
        Task.detached(priority: .userInitiated) {
            let r = PHAsset.fetchAssets(with: o)
            await MainActor.run { fetch = r }
        }
    }

    private func loadReceived() { if model.showReceived { received = queryReceived() } }
}

struct AssetCell: View {
    let asset: PHAsset
    @EnvironmentObject var model: AppModel
    @State private var img: UIImage?
    @State private var item: Item?

    private var selected: Bool { model.tray.contains { $0.id == asset.localIdentifier } }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Color.cell.aspectRatio(1, contentMode: .fit)
                .overlay {
                    if model.pending.contains(asset.localIdentifier) { PendingSlot() }
                    else if model.lifting.contains(asset.localIdentifier) { Color.bg }
                    else if let img = img { Image(uiImage: img).resizable().scaledToFill() }
                }
                .overlay(alignment: .bottomTrailing) {
                    if asset.mediaType == .video {
                        Image(systemName: "video.fill").font(.caption2).foregroundStyle(.white).padding(7)
                            .background(.black.opacity(0.35), in: Circle()).padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    if selected { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.accent2, lineWidth: 3) }
                }
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill").font(.title2).symbolRenderingMode(.palette)
                            .foregroundStyle(.black, Color.accent2).padding(8)
                    }
                }
                .scaleEffect(selected ? 0.96 : 1)
                .animation(.spring(duration: 0.2), value: selected)
                .overlay { DragSource(items: { dragItems() }, thumb: { img }, onTap: { toggle() }) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item?.name ?? "Photo")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { toggle() }
        .task(id: asset.localIdentifier) {
            if img == nil { img = await Thumbs.image(asset) }
            if item == nil { let a = asset; item = await Task.detached { Item.make(asset: a) }.value }
        }
        .onDisappear { img = nil }   // the grid is long: only what is on screen keeps its 512 px thumbnail
    }

    /// Holding any tile while files are selected takes the whole group, this one included.
    private func dragItems() -> [Item] {
        guard let me = item ?? Item.make(asset: asset) else { return model.tray }
        if model.tray.isEmpty { return [me] }
        if !selected { model.tray.append(me) }
        return model.tray
    }

    private func toggle() {
        UISelectionFeedbackGenerator().selectionChanged()
        if selected { model.tray.removeAll { $0.id == asset.localIdentifier } }
        else if let it = item ?? Item.make(asset: asset) { model.tray.append(it) }
    }
}

/// Where a file is while it travels: a dashed outline and a small blue ring.
struct PendingSlot: View {
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.bg
            RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            ProgressView().controlSize(.mini).tint(Color.accent2).padding(8)
        }
    }
}

struct ReceivedList: View {
    @EnvironmentObject var model: AppModel
    let files: [RecvFile]
    var body: some View {
        if files.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "tray").font(.largeTitle).foregroundStyle(Color.dimText)
                Text("Nothing received yet").font(.headline)
                Text("Drag a file from your Mac to the phone.").font(.subheadline).foregroundStyle(Color.dimText)
                Spacer()
            }
            .frame(maxWidth: .infinity).padding(24)
        } else {
            List(files) { f in
                Button { model.preview = f.url } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.fill").foregroundStyle(Color.accent2)
                        Text(f.name).lineLimit(1).truncationMode(.middle).foregroundStyle(.white)
                        Spacer()
                        Text(humanSize(f.size)).font(.footnote).foregroundStyle(Color.dimText)
                    }
                    .frame(minHeight: 44)
                }
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}

struct DocPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void
    func makeCoordinator() -> Coord { Coord(onPick) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let p = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        p.allowsMultipleSelection = true
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ c: UIDocumentPickerViewController, context: Context) {}
    final class Coord: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(_ f: @escaping ([URL]) -> Void) { onPick = f }
        func documentPicker(_ c: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPick(urls) }
    }
}

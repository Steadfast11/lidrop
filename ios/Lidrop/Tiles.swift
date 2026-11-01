import SwiftUI
import UIKit

extension Color {
    static let bg = Color(red: 0.063, green: 0.067, blue: 0.078)
    static let cell = Color(red: 0.133, green: 0.141, blue: 0.157)
    static let accent2 = Color(red: 0.30, green: 0.64, blue: 1)
    static let dimText = Color(red: 0.604, green: 0.627, blue: 0.667)
}

/// A tile, drawn as a small stack with a count badge when it stands for several files.
struct StackTile: View {
    let thumb: UIImage?
    let count: Int
    var body: some View {
        ZStack(alignment: .topTrailing) {
            if count > 1 {
                ForEach([2, 1], id: \.self) { k in
                    RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.29, green: 0.314, blue: 0.357).opacity(0.9 - 0.2 * Double(k)))
                        .offset(x: 3 * CGFloat(k), y: 3 * CGFloat(k))
                }
            }
            RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.227, green: 0.247, blue: 0.278))
                .overlay {
                    if let t = thumb { Image(uiImage: t).resizable().scaledToFill() } else { Text("FILE").font(.caption).foregroundStyle(.white) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            if count > 1 {
                Text("\(count)").font(.caption2.weight(.medium)).foregroundStyle(.black)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(Color.accent2, in: Capsule()).padding(4)
            }
        }
    }
}

/// Long-press-and-drag source backed by a UIKit gesture recognizer: touches are read straight from UIKit (no SwiftUI
/// gesture latency) and drive the UIKit overlay tile directly. `instant` picks the tile up at the first touch.
struct DragSource: UIViewRepresentable {
    @EnvironmentObject var model: AppModel
    let items: () -> [Item]
    let thumb: () -> UIImage?
    var onTap: (() -> Void)?
    var instant = false

    func makeCoordinator() -> Coord { Coord() }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        let g = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coord.handle(_:)))
        g.minimumPressDuration = instant ? 0 : 0.3
        g.allowableMovement = instant ? .greatestFiniteMagnitude : 10
        v.addGestureRecognizer(g)
        if !instant {
            let t = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coord.tap))
            v.addGestureRecognizer(t)
        }
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {
        context.coordinator.model = model
        context.coordinator.items = items
        context.coordinator.thumb = thumb
        context.coordinator.onTap = onTap
    }

    final class Coord: NSObject {
        var model: AppModel?
        var items: (() -> [Item])?
        var thumb: (() -> UIImage?)?
        var onTap: (() -> Void)?
        private var began = false

        @objc func tap() { onTap?() }

        @objc func handle(_ g: UILongPressGestureRecognizer) {
            guard let m = model, let v = g.view else { return }
            let p = g.location(in: m.overlay)
            switch g.state {
            case .began:
                guard let its = items?(), !its.isEmpty else { return }
                began = true
                m.drag.start(items: its, thumb: thumb?(), fx: p.x, fy: p.y, cell: v.bounds.width)
            case .changed: if began { m.drag.move(p.x, p.y) }
            case .ended: if began { m.drag.end() }; began = false
            case .cancelled, .failed: if began { m.drag.cancel() }; began = false
            default: break
            }
        }
    }
}

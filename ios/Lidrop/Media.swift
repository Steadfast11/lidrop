import Photos
import UIKit
import UniformTypeIdentifiers
import QuickLookThumbnailing

struct Item: Identifiable {
    enum Source { case asset(PHAsset, PHAssetResource), file(URL) }
    let id: String
    let name: String
    let mime: String
    let size: Int64
    let isVideo: Bool
    let date: Date?
    let source: Source

    static func make(asset: PHAsset) -> Item? {
        let rs = PHAssetResource.assetResources(for: asset)
        let want: [PHAssetResourceType] = asset.mediaType == .video ? [.fullSizeVideo, .video] : [.fullSizePhoto, .photo]
        guard let r = want.compactMap({ t in rs.first { $0.type == t } }).first ?? rs.first else { return nil }
        let size = (r.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
        let mime = UTType(r.uniformTypeIdentifier)?.preferredMIMEType ?? (asset.mediaType == .video ? "video/mp4" : "image/jpeg")
        return Item(id: asset.localIdentifier, name: r.originalFilename, mime: mime, size: size, isVideo: asset.mediaType == .video, date: asset.creationDate, source: .asset(asset, r))
    }

    static func make(url: URL) -> Item {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return Item(id: url.path, name: url.lastPathComponent, mime: mime, size: size, isVideo: mime.hasPrefix("video/"), date: nil, source: .file(url))
    }

    /// Local file URL with the bytes to send (assets are exported to a temp file; iCloud originals are fetched).
    func export() async throws -> URL {
        switch source {
        case .file(let u): return u
        case .asset(_, let r):
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lidrop-out/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(name)
            let o = PHAssetResourceRequestOptions()
            o.isNetworkAccessAllowed = true
            return try await withCheckedThrowingContinuation { cont in
                PHAssetResourceManager.default().writeData(for: r, toFile: url, options: o) { err in
                    if let err = err { cont.resume(throwing: err) } else { cont.resume(returning: url) }
                }
            }
        }
    }

    /// Removes what `export()` wrote; picked and shared files stay where they are.
    func cleanUp(_ url: URL) {
        if case .asset = source { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }

    func thumbnail() async -> UIImage? {
        switch source {
        case .asset(let a, _): return await Thumbs.image(a)
        case .file(let u): return await Thumbs.image(url: u)
        }
    }
}

enum Thumbs {
    static let mgr = PHCachingImageManager()

    static func image(_ asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { cont in
            let o = PHImageRequestOptions()
            o.deliveryMode = .highQualityFormat
            o.resizeMode = .fast
            o.isNetworkAccessAllowed = true
            var done = false
            mgr.requestImage(for: asset, targetSize: CGSize(width: 512, height: 512), contentMode: .aspectFit, options: o) { img, _ in
                if done { return }
                done = true
                cont.resume(returning: img.map { shapeThumb($0) })
            }
        }
    }

    static func image(url: URL) async -> UIImage? {
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 512, height: 512), scale: 1, representationTypes: .all)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) else { return nil }
        return shapeThumb(rep.uiImage)
    }
}

struct RecvFile: Identifiable {
    let url: URL
    let size: Int64
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// Last `limit` files in the app's Files folder (what this app received), newest first.
func queryReceived(limit: Int = 20) -> [RecvFile] {
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
    let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
    let rows = urls.compactMap { u -> (URL, Date, Int64)? in
        guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
        return (u, v.contentModificationDate ?? .distantPast, Int64(v.fileSize ?? 0))
    }
    return rows.sorted { $0.1 > $1.1 }.prefix(limit).map { RecvFile(url: $0.0, size: $0.2) }
}

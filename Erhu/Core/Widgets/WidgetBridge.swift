import UIKit
import WidgetKit

/// Keeps the Home Screen widgets up to date: whenever the Lock Screen's now-playing information
/// changes, the same song, state, cover and upcoming songs go into the shared App Group folder and
/// the widgets are asked to redraw. A playing song's position moving on by itself is not written;
/// the widgets count it forward themselves.
@MainActor
final class WidgetBridge {
    static let shared = WidgetBridge()
    private static let upNextCount = 4
    private static let artworkPixels: CGFloat = 400

    private var last: NowPlayingSnapshot?
    /// The cover image last written, so a new cover for the same song is written again.
    private var writtenArtwork: ObjectIdentifier?
    /// Whether anything was written since launch (a stopped player at launch clears the old file once).
    private var hasPublished = false
    private let queue = DispatchQueue(label: "erhu.widget-bridge", qos: .utility)

    /// [upcoming]: the queue after the playing song, in play order.
    func publish(song: Song?, isPlaying: Bool, positionMs: Int64, durationMs: Int64, upcoming: [Song], artwork: UIImage?) {
        guard let folder = WidgetShared.containerURL else { return }
        let snapshot = song.map { song in
            NowPlayingSnapshot(
                title: song.title, artist: song.artist, album: song.album, isPlaying: isPlaying,
                positionMs: positionMs, durationMs: durationMs, capturedAt: Date(),
                artworkFile: artwork == nil ? nil : "artwork-\(song.id).jpg",
                upNext: upcoming.prefix(Self.upNextCount).map { NowPlayingSnapshot.Track(title: $0.title, artist: $0.artist) })
        }
        let artworkID = artwork.map(ObjectIdentifier.init)
        if hasPublished, artworkID == writtenArtwork || artwork == nil {
            if let snapshot, let last, last.showsSameAs(snapshot) { return }
            if snapshot == nil, last == nil { return }
        }
        hasPublished = true
        last = snapshot

        var cover: (name: String, image: UIImage)?
        if let name = snapshot?.artworkFile, let artwork, artworkID != writtenArtwork {
            writtenArtwork = artworkID
            cover = (name, artwork)
        }
        if snapshot == nil { writtenArtwork = nil }

        queue.async {
            if let cover, let data = Self.scaled(cover.image).jpegData(compressionQuality: 0.85) {
                try? data.write(to: folder.appendingPathComponent(cover.name), options: .atomic)
            }
            Self.removeOldArtwork(in: folder, keeping: snapshot?.artworkFile)
            let file = folder.appendingPathComponent(WidgetShared.snapshotFileName)
            if let snapshot, let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: file, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: file)
            }
            DispatchQueue.main.async { WidgetCenter.shared.reloadTimelines(ofKind: WidgetShared.kind) }
        }
    }

    private nonisolated static func scaled(_ image: UIImage) -> UIImage {
        let side = max(image.size.width, image.size.height)
        guard side > artworkPixels else { return image }
        let scale = artworkPixels / side
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    private nonisolated static func removeOldArtwork(in folder: URL, keeping name: String?) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for file in files where file.hasPrefix("artwork-") && file != name {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
        }
    }
}

import Foundation

struct ArtworkFetchProgress: Sendable {
    typealias Stamp = ProgressFileStamp
    struct Entry: Codable, Sendable {
        let album: Album
        let stamp: Stamp?
        let hasArtwork: Bool
        func matches(_ album: Album, stamp: Stamp?) -> Bool {
            self.album.id == album.id && self.album.title == album.title && self.album.artist == album.artist && self.stamp == stamp
        }
    }
    struct Manifest: Codable {
        var version = 1
        let ids: [Int64]
        let total: Int
    }
    let url: URL?
    var manifest: ProgressFile<Manifest> { ProgressFile(url: url) }
    var artists: ProgressFile<[String: ArtworkStatus]> { ProgressFile(url: url?.appendingPathExtension("artists")) }
    func album(_ id: Int64) -> ProgressFile<Entry> {
        ProgressFile(url: url?.appendingPathExtension("albums").appendingPathComponent("\(id).json"))
    }
    func clearAlbums() {
        manifest.remove()
        if let folder = url?.appendingPathExtension("albums") { try? FileManager.default.removeItem(at: folder) }
    }
}

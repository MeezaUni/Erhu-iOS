import Foundation
import SwiftUI
import UIKit

/// Covers of server music, kept on disk (Caches/Erhu/server-covers) so streamed songs, their
/// albums and the Recently streamed shelf show artwork at once, and still do when the server
/// can't be reached. Usable from any thread.
enum ServerCovers {
    static let didChange = Notification.Name("ServerCovers.didChange")
    private static let lock = NSLock()
    /// Stream cache file path → the cover file of that song.
    private static var coverByStreamFile: [String: URL] = [:]
    /// Stream cache file path → a library song of the same album, whose cover is used instead
    /// (your own copy is usually sharper, and may be a cover you chose).
    private static var libraryCoverByStreamFile: [String: URL] = [:]
    private static var inFlight: Set<String> = []

    static var folder: URL { LibraryPaths.cachesFolder.appendingPathComponent("server-covers", isDirectory: true) }

    /// Covers are kept in two sizes: small ones for tiles and rows (quick to fetch, even on
    /// mobile data) and large ones for pages and Now Playing.
    enum Size: Sendable {
        case small, large
        var pixels: Int { self == .small ? 300 : 800 }
        init(maxPixels: Int) { self = maxPixels <= 400 ? .small : .large }
    }

    /// Where the cover [coverArt] of a server is kept, at [size].
    static func fileURL(accountId: UUID, coverArt: String, size: Size = .large) -> URL {
        folder.appendingPathComponent(accountId.uuidString, isDirectory: true)
            .appendingPathComponent(String(ServerStreamPaths.hash(coverArt), radix: 16) + (size == .small ? "-s.img" : ".img"))
    }

    static func register(streamFile: URL, cover: URL) {
        lock.withLock { coverByStreamFile[streamFile.path] = cover }
    }

    static func register(streamFile: URL, librarySong: URL?) {
        lock.withLock { libraryCoverByStreamFile[streamFile.path] = librarySong }
    }

    /// The library song whose cover a streamed song's file shows (nil: its server's cover).
    static func librarySong(forStreamFile url: URL) -> URL? {
        lock.withLock { libraryCoverByStreamFile[url.path] }
    }

    /// The saved cover of a streamed song's file, for [ArtworkLoader] when the audio file has no
    /// embedded picture or hasn't been fetched yet: the large one, or the small one until then.
    static func data(forStreamFile url: URL) -> Data? {
        guard let cover = lock.withLock({ coverByStreamFile[url.path] }) else { return nil }
        if let data = try? Data(contentsOf: cover) { return data }
        let small = cover.deletingPathExtension().path + "-s.img"
        return try? Data(contentsOf: URL(fileURLWithPath: small))
    }

    static func hasCover(at file: URL) -> Bool { FileManager.default.fileExists(atPath: file.path) }

    /// Downloads [remote] to [file] unless it is already there or being fetched. Posts [didChange]
    /// with the file's path when it arrives.
    static func fetch(_ remote: URL, to file: URL, session: URLSession, then done: (@Sendable () -> Void)? = nil) {
        if hasCover(at: file) { return }
        let claimed = lock.withLock { inFlight.insert(file.path).inserted }
        guard claimed else { return }
        Task.detached(priority: .utility) {
            defer { lock.withLock { _ = inFlight.remove(file.path) } }
            var request = URLRequest(url: remote)
            request.timeoutInterval = 30
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  UIImage(data: data) != nil else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            done?()
            await MainActor.run { NotificationCenter.default.post(name: didChange, object: file.path) }
        }
    }
}

/// A server cover: from the disk cache when it is there, otherwise fetched once from the server
/// (small for tiles and rows, large for pages). A large copy already saved is used for tiles too.
struct ServerCoverView: View {
    let accountId: UUID
    let coverArt: String?
    var maxPixels = 400
    var placeholder = "music.note"
    @Environment(ServerStore.self) private var servers
    @Environment(\.palette) private var palette
    @State private var image: UIImage?
    @State private var revision = 0

    private var size: ServerCovers.Size { ServerCovers.Size(maxPixels: maxPixels) }
    private var file: URL? { coverArt.map { ServerCovers.fileURL(accountId: accountId, coverArt: $0, size: size) } }
    private var largeFile: URL? { coverArt.map { ServerCovers.fileURL(accountId: accountId, coverArt: $0, size: .large) } }

    var body: some View {
        // A cover already decoded shows at once, without a placeholder flash.
        let shown = image ?? [file, largeFile].compactMap { $0 }.lazy.compactMap { file in
            [maxPixels, 1200, 800, 400, 300, 144].lazy.compactMap { ArtworkLoader.shared.cachedImage(atPath: file.path, maxPixels: $0) }.first
        }.first
        ZStack {
            if let image = shown {
                FillImage(image: image)
            } else {
                Rectangle().fill(palette.surfaceVariant)
                Image(systemName: placeholder).font(.system(size: 20, weight: .medium)).foregroundStyle(palette.onSurfaceVariant)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ServerCovers.didChange)) { note in
            let path = note.object as? String
            if path == file?.path || path == largeFile?.path { revision += 1 }
        }
        .task(id: "\(file?.path ?? "")|\(maxPixels)|\(revision)") {
            guard let file, let largeFile, let coverArt else { image = nil; return }
            if ServerCovers.hasCover(at: largeFile) {
                image = await ArtworkLoader.shared.image(atPath: largeFile.path, maxPixels: maxPixels)
            } else if ServerCovers.hasCover(at: file) {
                image = await ArtworkLoader.shared.image(atPath: file.path, maxPixels: maxPixels)
            } else if let client = servers.client(for: accountId) {
                ServerCovers.fetch(client.coverArtURL(coverArt, size: size.pixels), to: file, session: client.session)
            }
            // A tile on Wi-Fi also fetches the large cover, so its page opens with it at once.
            if size == .small, !servers.networkIsExpensive, !ServerCovers.hasCover(at: largeFile),
               let client = servers.client(for: accountId) {
                ServerCovers.fetch(client.coverArtURL(coverArt, size: ServerCovers.Size.large.pixels), to: largeFile, session: client.session)
            }
        }
        .accessibilityHidden(true)
    }
}

extension ServerCovers {
    /// Gets the large cover of [coverArt] ready for a page about to open: decoded from the phone
    /// while the page slides in, or fetched if it isn't there yet.
    @MainActor
    static func prepareLarge(accountId: UUID, coverArt: String?, servers: ServerStore) {
        guard let coverArt else { return }
        let file = fileURL(accountId: accountId, coverArt: coverArt, size: .large)
        if hasCover(at: file) {
            Task { _ = await ArtworkLoader.shared.image(atPath: file.path, maxPixels: 1200) }
        } else if let client = servers.client(for: accountId) {
            fetch(client.coverArtURL(coverArt, size: Size.large.pixels), to: file, session: client.session)
        }
    }
}

/// Marks music that streams from a server rather than living on this device.
struct StreamBadge: View {
    @Environment(\.palette) private var palette

    var body: some View {
        Image(systemName: "dot.radiowaves.up.forward")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .padding(5)
            .background(Circle().fill(.black.opacity(0.55)))
            .accessibilityLabel("Streams from your server")
    }
}

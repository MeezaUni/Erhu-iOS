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
    private static var inFlight: Set<String> = []

    static var folder: URL { LibraryPaths.cachesFolder.appendingPathComponent("server-covers", isDirectory: true) }

    /// Where the cover [coverArt] of a server is kept.
    static func fileURL(accountId: UUID, coverArt: String) -> URL {
        folder.appendingPathComponent(accountId.uuidString, isDirectory: true)
            .appendingPathComponent(String(ServerStreamPaths.hash(coverArt), radix: 16) + ".img")
    }

    static func register(streamFile: URL, cover: URL) {
        lock.withLock { coverByStreamFile[streamFile.path] = cover }
    }

    /// The saved cover of a streamed song's file, for [ArtworkLoader] when the audio file has no
    /// embedded picture or hasn't been fetched yet.
    static func data(forStreamFile url: URL) -> Data? {
        guard let cover = lock.withLock({ coverByStreamFile[url.path] }) else { return nil }
        return try? Data(contentsOf: cover)
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

/// A server cover: from the disk cache when it is there, otherwise fetched once from the server.
struct ServerCoverView: View {
    let accountId: UUID
    let coverArt: String?
    var maxPixels = 400
    var placeholder = "music.note"
    @Environment(ServerStore.self) private var servers
    @Environment(\.palette) private var palette
    @State private var image: UIImage?
    @State private var revision = 0

    private var file: URL? { coverArt.map { ServerCovers.fileURL(accountId: accountId, coverArt: $0) } }

    var body: some View {
        ZStack {
            if let image {
                FillImage(image: image)
            } else {
                Rectangle().fill(palette.surfaceVariant)
                Image(systemName: placeholder).font(.system(size: 20, weight: .medium)).foregroundStyle(palette.onSurfaceVariant)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ServerCovers.didChange)) { note in
            if note.object as? String == file?.path { revision += 1 }
        }
        .task(id: "\(file?.path ?? "")|\(maxPixels)|\(revision)") {
            guard let file, let coverArt else { image = nil; return }
            if ServerCovers.hasCover(at: file) {
                image = await ArtworkLoader.shared.image(atPath: file.path, maxPixels: maxPixels)
            } else if let client = servers.client(for: accountId) {
                ServerCovers.fetch(client.coverArtURL(coverArt, size: 800), to: file, session: client.session)
            }
        }
        .accessibilityHidden(true)
    }
}

import Foundation
import Observation

/// How far each streamed song being fetched has got (0…1), by path, for the player's spinner.
/// A song whose size the server doesn't send (a converted MP3) has no entry while it loads.
@MainActor
@Observable
final class StreamLoading {
    static let shared = StreamLoading()
    private(set) var progress: [String: Double] = [:]
    private(set) var active: Set<String> = []
    private init() {}

    func started(_ path: String) { active.insert(path) }
    func set(_ path: String, _ fraction: Double) { progress[path] = min(max(fraction, 0), 1) }
    func finished(_ path: String) {
        active.remove(path)
        progress[path] = nil
    }

    /// The fraction loaded of [song], or nil when it isn't loading or its size is unknown.
    func fraction(of song: Song) -> Double? { progress[song.path] }
    func isLoading(_ song: Song) -> Bool { active.contains(song.path) }
}

/// Where streamed songs live. A streamed song is an ordinary [Song] whose path starts with
/// [prefix]; its file is fetched from the server into the caches folder before it plays, so the
/// player, equalizer, waveform, transitions and gapless playback work on it as on any song.
/// Not tied to an actor: [Song.url] uses it from any thread.
enum ServerStreamPaths {
    static let prefix = "erhu-stream:"

    static func isStream(_ path: String) -> Bool { path.hasPrefix(prefix) }

    static var cacheFolder: URL { LibraryPaths.cachesFolder.appendingPathComponent("server-stream", isDirectory: true) }

    static func cacheURL(forPath path: String) -> URL {
        cacheFolder.appendingPathComponent(String(path.dropFirst(prefix.count)))
    }

    /// A stable 64-bit FNV-1a hash, used for file names and song IDs.
    static func hash(_ text: String) -> UInt64 {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return value
    }

    /// Library songs have positive IDs; streamed songs get a stable negative one, so they can't
    /// collide with the library and listening statistics simply skip them.
    static func songId(accountId: UUID, remoteId: String) -> Int64 {
        -(Int64(hash("\(accountId.uuidString)/\(remoteId)") & 0x3fff_ffff_ffff_ffff) + 1)
    }

    /// "erhu-stream:<account>/<song hash>.<quality>.<ext>": the quality is part of the name, so
    /// changing it never plays a copy fetched at another quality.
    static func path(accountId: UUID, remoteId: String, quality: StreamQuality, originalExtension: String) -> String {
        let ext = quality.transcoding?.format ?? originalExtension
        return "\(prefix)\(accountId.uuidString)/\(String(hash(remoteId), radix: 16)).\(quality.rawValue).\(ext)"
    }
}

extension Song {
    /// Played from a music server rather than the library.
    var isStream: Bool { ServerStreamPaths.isStream(path) }
}

/// What is saved with the queue for a streamed song, so it can be rebuilt after the app restarts.
struct PersistedStreamSong: Codable, Equatable, Sendable {
    let accountId: UUID
    let remote: ServerSong
    let quality: StreamQuality
}

enum ServerStreamError: LocalizedError {
    case unknownSong
    case notAudio
    case notConnected

    var errorDescription: String? {
        switch self {
        case .unknownSong: String(localized: "This song came from a music server in an earlier session. Play it again from the server page.")
        case .notAudio: String(localized: "The server didn't send audio for this song.")
        case .notConnected: String(localized: "This song's server isn't connected in Erhu. Add the server again in Music Server to play it.")
        }
    }
}

/// Fetches streamed songs into the cache, a few songs ahead, and reports plays to the server.
@MainActor
final class ServerStream {
    static let shared = ServerStream()

    private struct Source: Sendable {
        let accountId: UUID
        let remoteId: String
        let quality: StreamQuality
    }

    /// Supplies the client for an account (set by [ServerStore]).
    var clientProvider: ((UUID) -> SubsonicClient?)?
    /// Cached streams are trimmed, oldest first, to stay under this size.
    var cacheLimitBytes: Int64 = 2 * 1024 * 1024 * 1024

    /// Called when a streamed song starts playing (set by [ServerStore], for Recently streamed).
    var onStarted: ((UUID, ServerSong) -> Void)?

    private var sources: [String: Source] = [:]
    private var remotes: [String: ServerSong] = [:]
    private var pathsById: [Int64: String] = [:]
    private var inFlight: [String: Task<Void, Error>] = [:]
    private var prefetchTask: Task<Void, Never>?

    private init() {}

    /// A playable song for [remote] on [account].
    func song(for remote: ServerSong, account: ServerAccount, quality: StreamQuality, favourite: Bool = false) -> Song {
        song(for: remote, accountId: account.id, quality: quality, favourite: favourite)
    }

    /// The details to save for a streamed song in the queue (nil if it isn't one known here).
    func persisted(_ song: Song) -> PersistedStreamSong? {
        guard let source = sources[song.path], let remote = remotes[song.path] else { return nil }
        return PersistedStreamSong(accountId: source.accountId, remote: remote, quality: source.quality)
    }

    /// A streamed song saved with the queue, playable again (fetched when it plays).
    func restore(_ saved: PersistedStreamSong) -> Song {
        song(for: saved.remote, accountId: saved.accountId, quality: saved.quality, favourite: saved.remote.starred != nil)
    }

    private func song(for remote: ServerSong, accountId: UUID, quality: StreamQuality, favourite: Bool) -> Song {
        let path = ServerStreamPaths.path(accountId: accountId, remoteId: remote.id, quality: quality, originalExtension: remote.fileExtension)
        let id = ServerStreamPaths.songId(accountId: accountId, remoteId: remote.id)
        sources[path] = Source(accountId: accountId, remoteId: remote.id, quality: quality)
        remotes[path] = remote
        // The cover is fetched now, ahead of the audio, so the song shows artwork everywhere at once.
        if let coverArt = remote.coverArt {
            let streamFile = ServerStreamPaths.cacheURL(forPath: path)
            let cover = ServerCovers.fileURL(accountId: accountId, coverArt: coverArt)
            ServerCovers.register(streamFile: streamFile, cover: cover)
            if let client = clientProvider?(accountId) {
                ServerCovers.fetch(client.coverArtURL(coverArt, size: 800), to: cover, session: client.session) {
                    ArtworkLoader.shared.forget(path: streamFile.path)
                }
            }
        }
        pathsById[id] = path
        return Song(id: id, title: remote.title, artist: remote.artist ?? "", album: remote.album ?? "",
                    durationMs: Int64(remote.duration ?? 0) * 1000, path: path,
                    trackNumber: remote.track ?? 0, discNumber: remote.discNumber ?? 1, year: remote.year ?? 0,
                    isFavorite: favourite, genre: remote.genre, bpm: (remote.bpm ?? 0) > 0 ? remote.bpm : nil,
                    fileSize: quality == .original ? (remote.size ?? 0) : 0,
                    codec: quality.transcoding?.format ?? remote.suffix, bitrate: quality.transcoding?.maxBitRate ?? remote.bitRate ?? 0)
    }

    func isCached(_ song: Song) -> Bool {
        let values = try? song.url.resourceValues(forKeys: [.fileSizeKey])
        return (values?.fileSize ?? 0) > 0
    }

    /// Fetches [song] into the cache unless it is already there. Concurrent requests share one fetch.
    func fetch(_ song: Song) async throws {
        guard song.isStream, !isCached(song) else { return }
        let path = song.path
        if let running = inFlight[path] { return try await running.value }
        guard let source = sources[path] else { throw ServerStreamError.unknownSong }
        guard let client = clientProvider?(source.accountId) else { throw ServerStreamError.notConnected }
        let destination = song.url
        let task = Task.detached(priority: .userInitiated) {
            var request = URLRequest(url: client.streamURL(source.remoteId, quality: source.quality))
            request.timeoutInterval = 60
            let (bytes, response) = try await client.session.bytes(for: request)
            let type = (response.mimeType ?? "").lowercased()
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) || type.contains("json") || type.contains("xml") {
                // An error arrives as a Subsonic response instead of audio.
                var body = Data()
                for try await byte in bytes {
                    body.append(byte)
                    if body.count > 1 << 20 { break }
                }
                _ = try SubsonicClient.decode(body, response: response)
                throw ServerStreamError.notAudio
            }
            // Written to a ".part" file as it arrives (reporting progress), then moved into place,
            // so the player never sees half a song.
            let folder = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let partial = folder.appendingPathComponent(UUID().uuidString + ".part")
            guard FileManager.default.createFile(atPath: partial.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let expected = response.expectedContentLength
            do {
                let handle = try FileHandle(forWritingTo: partial)
                defer { try? handle.close() }
                var buffer = Data()
                buffer.reserveCapacity(1 << 16)
                var written: Int64 = 0
                var reported = 0.0
                for try await byte in bytes {
                    buffer.append(byte)
                    guard buffer.count >= 1 << 16 else { continue }
                    try handle.write(contentsOf: buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    if expected > 0 {
                        let fraction = Double(written) / Double(expected)
                        if fraction - reported >= 0.01 {
                            reported = fraction
                            await MainActor.run { StreamLoading.shared.set(path, fraction) }
                        }
                    }
                }
                try handle.write(contentsOf: buffer)
            } catch {
                try? FileManager.default.removeItem(at: partial)
                throw error
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: partial, to: destination)
        }
        inFlight[path] = task
        StreamLoading.shared.started(path)
        defer {
            inFlight[path] = nil
            StreamLoading.shared.finished(path)
        }
        try await task.value
        // Artwork asked for before the file arrived was remembered as missing: look again.
        ArtworkLoader.shared.forget(path: destination.path)
        trimCache()
    }

    /// Fetches the next streamed songs in the background, one at a time, replacing any earlier request.
    func prefetch(_ songs: [Song]) {
        let pending = songs.filter { $0.isStream && !isCached($0) }
        prefetchTask?.cancel()
        guard !pending.isEmpty else { prefetchTask = nil; return }
        prefetchTask = Task { [weak self] in
            for song in pending {
                guard !Task.isCancelled else { return }
                try? await self?.fetch(song)
            }
        }
    }

    /// The server and server song behind a streamed [song], while it is known in this session.
    func remote(for song: Song) -> (accountId: UUID, song: ServerSong)? {
        guard let source = sources[song.path], let remote = remotes[song.path] else { return nil }
        return (source.accountId, remote)
    }

    /// A streamed song became the current song.
    func noteStarted(_ song: Song) {
        guard let source = sources[song.path], let remote = remotes[song.path] else { return }
        onStarted?(source.accountId, remote)
    }

    /// Reports a counted play of a streamed song to its server.
    func reportPlay(songId: Int64) {
        guard let path = pathsById[songId], let source = sources[path], let client = clientProvider?(source.accountId) else { return }
        Task.detached(priority: .utility) { try? await client.scrobble(source.remoteId) }
    }

    /// Keeps the cache under [cacheLimitBytes], removing the least recently fetched songs first.
    /// Songs being fetched, and anything fetched in the last hour, are kept.
    func trimCache() {
        let folder = ServerStreamPaths.cacheFolder
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return }
        var files: [(url: URL, size: Int64, date: Date)] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            files.append((url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast))
        }
        var total = files.reduce(0) { $0 + $1.size }
        guard total > cacheLimitBytes else { return }
        let busy = Set(inFlight.keys.map { ServerStreamPaths.cacheURL(forPath: $0).standardizedFileURL })
        let recent = Date().addingTimeInterval(-3600)
        for file in files.sorted(by: { $0.date < $1.date }) where total > cacheLimitBytes {
            guard file.date < recent, !busy.contains(file.url.standardizedFileURL) else { continue }
            if (try? FileManager.default.removeItem(at: file.url)) != nil { total -= file.size }
        }
    }

    /// Removes every cached stream (Settings → Music Server → Clear streaming cache).
    func clearCache() {
        try? FileManager.default.removeItem(at: ServerStreamPaths.cacheFolder)
    }

    /// Bytes used by cached streams.
    func cacheSize() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: ServerStreamPaths.cacheFolder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator { total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }
}

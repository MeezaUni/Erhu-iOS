import Foundation
import Observation

/// A metadata-only scan. Video downloads remain an explicit, separate action.
@MainActor @Observable
final class MotionCoverAvailability {
    struct Result {
        let album: Album
        let match: AppleMotionMatch
    }
    private(set) var results: [Int64: Result] = [:]
    private(set) var checking = false
    private(set) var checked = 0
    private(set) var total = 0
    private(set) var message: String?
    private(set) var hasChecked = false
    @ObservationIgnored private var task: Task<Void, Never>?
    private struct Entry: Codable {
        let id: Int64
        let title: String
        let artist: String
        let match: AppleMotionMatch?
        func matches(_ album: Album) -> Bool { id == album.id && title == album.title && artist == album.artist }
        var album: Album { Album(id: id, title: title, artist: artist, artistId: 0, songCount: 0, year: 0) }
    }
    private struct Checkpoint: Codable {
        var version = 1
        let total: Int
        let entries: [Entry]
    }
    @ObservationIgnored private var completed: [Int64: Entry] = [:]
    @ObservationIgnored private var freshMatches: Set<Int64> = []
    @ObservationIgnored private let checkpointURL: URL?
    @ObservationIgnored private let find: @Sendable (Album) async throws -> AppleMotionMatch?
    @ObservationIgnored private let pause: Duration

    init(pause: Duration = .milliseconds(500), checkpointURL: URL? = nil, find: @escaping @Sendable (Album) async throws -> AppleMotionMatch?) {
        self.pause = pause
        self.find = find
        self.checkpointURL = checkpointURL
        if let checkpointURL, let data = try? Data(contentsOf: checkpointURL),
           let saved = try? JSONDecoder().decode(Checkpoint.self, from: data), saved.version == 1 {
            for entry in saved.entries {
                completed[entry.id] = entry
                if let match = entry.match { results[entry.id] = Result(album: entry.album, match: match) }
            }
            checked = completed.count; total = saved.total; hasChecked = true
            message = String(localized: "Saved progress: checked \(checked) of \(total) albums. Continue to check remaining or newly added albums.")
        }
    }

    func match(for album: Album) -> AppleMotionMatch? {
        guard let result = results[album.id], result.album.title == album.title, result.album.artist == album.artist else { return nil }
        return result.match
    }

    func remaining(in albums: [Album]) -> Int {
        albums.filter { completed[$0.id]?.matches($0) != true }.count
    }

    /// Restored catalogue URLs may expire; refresh before a download, while retaining availability.
    func freshMatch(for album: Album) -> AppleMotionMatch? {
        freshMatches.contains(album.id) ? match(for: album) : nil
    }

    private func saveProgress() throws {
        guard let checkpointURL else { return }
        try FileManager.default.createDirectory(at: checkpointURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let snapshot = Checkpoint(total: total, entries: completed.values.sorted { $0.id < $1.id })
        try JSONEncoder().encode(snapshot).write(to: checkpointURL, options: .atomic)
    }

    func check(_ albums: [Album], restart: Bool = false) {
        beginCheck(albums, restart: restart, singleAlbum: false)
    }

    /// A menu check refreshes only this album and retains the library scan's checkpoint.
    func checkAlbum(_ album: Album, completion: (@MainActor (String) -> Void)? = nil) {
        beginCheck([album], restart: false, singleAlbum: true, completion: completion)
    }

    private func beginCheck(_ albums: [Album], restart: Bool, singleAlbum: Bool, completion: (@MainActor (String) -> Void)? = nil) {
        guard !checking else { return }
        if restart { completed = [:]; results = [:]; freshMatches = [] }
        if !singleAlbum {
            completed = completed.filter { key, previous in
                albums.contains { $0.id == key && previous.matches($0) }
            }
            results = results.filter { key, result in albums.contains { $0.id == key && $0.title == result.album.title && $0.artist == result.album.artist } }
        }
        checked = completed.count
        total = singleAlbum ? max(total, completed.count + albums.filter { completed[$0.id] == nil }.count) : albums.count
        checking = true; message = nil; hasChecked = true
        task = Task {
            defer {
                checking = false; task = nil
                if let completion { completion(message ?? String(localized: "The animated-cover check finished.")) }
            }
            do { try saveProgress() } catch { message = String(localized: "Couldn’t save scan progress: \(error.localizedDescription)"); return }
            for album in albums {
                if !singleAlbum, completed[album.id] != nil { continue }
                do {
                    try Task.checkCancellation()
                    let match = try await find(album)
                    try Task.checkCancellation()
                    if let match { results[album.id] = Result(album: album, match: match) }
                    else { results[album.id] = nil }
                    completed[album.id] = Entry(id: album.id, title: album.title, artist: album.artist, match: match)
                    freshMatches.insert(album.id)
                    checked = completed.count
                    try saveProgress()
                    if !singleAlbum, checked < total { try await Task.sleep(for: pause) }
                } catch {
                    message = Task.isCancelled ? String(localized: "Check stopped. Continue to check the remaining albums.")
                        : String(localized: "Check paused: \(error.localizedDescription) Continue later to check the remaining albums.")
                    return
                }
            }
            if singleAlbum, let album = albums.first {
                message = match(for: album) == nil ? String(localized: "No matching animated cover found for \(album.title).")
                    : String(localized: "An animated cover is available for \(album.title).")
            } else {
                message = String(localized: "Albums checked: \(checked). Motion covers available: \(results.count).")
            }
        }
    }

    func cancel() { task?.cancel() }
}

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
            message = "Saved progress: checked \(checked) of \(total) albums. Continue to check remaining or newly added albums."
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
        guard !checking else { return }
        if restart { completed = [:]; results = [:]; freshMatches = [] }
        completed = completed.filter { key, previous in
            albums.contains { $0.id == key && previous.matches($0) }
        }
        checked = completed.count; total = albums.count; checking = true; message = nil; hasChecked = true
        results = results.filter { key, result in albums.contains { $0.id == key && $0.title == result.album.title && $0.artist == result.album.artist } }
        task = Task {
            do { try saveProgress() } catch { checking = false; message = "Couldn’t save scan progress: \(error.localizedDescription)"; task = nil; return }
            defer { checking = false; task = nil }
            for album in albums {
                if completed[album.id] != nil { continue }
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
                    if checked < total { try await Task.sleep(for: pause) }
                } catch {
                    message = Task.isCancelled ? "Check stopped. Continue to check the remaining albums."
                        : "Check paused: \(error.localizedDescription) Continue later to check the remaining albums."
                    return
                }
            }
            message = "Checked \(checked) albums. \(results.count) motion cover\(results.count == 1 ? "" : "s") available."
        }
    }

    func cancel() { task?.cancel() }
}

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
    @ObservationIgnored private var completed: [Int64: Album] = [:]
    @ObservationIgnored private let find: @Sendable (Album) async throws -> AppleMotionMatch?
    @ObservationIgnored private let pause: Duration

    init(pause: Duration = .milliseconds(500), find: @escaping @Sendable (Album) async throws -> AppleMotionMatch?) {
        self.pause = pause
        self.find = find
    }

    func match(for album: Album) -> AppleMotionMatch? {
        guard let result = results[album.id], result.album.title == album.title, result.album.artist == album.artist else { return nil }
        return result.match
    }

    func check(_ albums: [Album], restart: Bool = false) {
        guard !checking else { return }
        if restart || (hasChecked && checked == total) { completed = [:] }
        completed = completed.filter { key, previous in
            albums.contains { $0.id == key && $0.title == previous.title && $0.artist == previous.artist }
        }
        checked = completed.count; total = albums.count; checking = true; message = nil; hasChecked = true
        results = results.filter { key, result in albums.contains { $0.id == key && $0.title == result.album.title && $0.artist == result.album.artist } }
        task = Task {
            defer { checking = false; task = nil }
            for album in albums {
                if completed[album.id] != nil { continue }
                do {
                    try Task.checkCancellation()
                    let match = try await find(album)
                    try Task.checkCancellation()
                    if let match { results[album.id] = Result(album: album, match: match) }
                    else { results[album.id] = nil }
                    completed[album.id] = album
                    checked += 1
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

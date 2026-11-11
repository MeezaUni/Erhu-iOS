import Foundation
import Observation

enum MotionCoverDownloadResult { case saved, unavailable }

/// A single cancellable worker; every finished cover is committed before the next starts.
@MainActor @Observable
final class MotionCoverDownloads {
    private(set) var isRunning = false
    private(set) var isStopping = false
    private(set) var current: Album?
    private(set) var total = 0
    private(set) var completed = 0
    private(set) var saved = 0
    private(set) var failed = 0
    private(set) var unavailable = 0
    private(set) var message: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    static func pending(_ albums: [Album], available: Set<Int64>, downloaded: Set<Int64>) -> [Album] {
        var seen = Set<Int64>()
        return albums.filter { available.contains($0.id) && !downloaded.contains($0.id) && seen.insert($0.id).inserted }
    }

    func start(_ albums: [Album], download: @escaping @MainActor (Album) async throws -> MotionCoverDownloadResult) {
        guard !isRunning else { return }
        var seen = Set<Int64>()
        let queue = albums.filter { seen.insert($0.id).inserted }
        guard !queue.isEmpty else { return }
        isRunning = true; isStopping = false; total = queue.count; completed = 0; saved = 0; failed = 0; unavailable = 0; message = nil
        task = Task {
            defer { current = nil; isRunning = false; isStopping = false; task = nil }
            for album in queue {
                guard !Task.isCancelled else { stopped(); return }
                current = album
                do {
                    let result = try await download(album)
                    switch result {
                    case .saved: saved += 1
                    case .unavailable: unavailable += 1
                    }
                    completed += 1
                    if Task.isCancelled { stopped(); return }
                } catch {
                    if error is CancellationError || Task.isCancelled { stopped(); return }
                    failed += 1; completed += 1
                    let failure = error as NSError
                    if failure.domain == NSCocoaErrorDomain && failure.code == NSFileWriteOutOfSpaceError {
                        message = String(localized: "Storage is full. Covers saved: \(saved). Free space, then try again.")
                        return
                    }
                }
            }
            var summary = String(localized: "Covers saved: \(saved).")
            if unavailable > 0 { summary += " " + String(localized: "No longer available: \(unavailable).") }
            if failed > 0 { summary += " " + String(localized: "Failed: \(failed). Tap Download all to retry the remaining covers.") }
            message = summary
        }
    }

    func stop() {
        guard isRunning else { return }
        isStopping = true
        task?.cancel()
    }

    private func stopped() {
        message = String(localized: "Download stopped. Covers saved: \(saved). Download all resumes the remaining covers.")
    }
}

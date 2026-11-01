import Foundation
import Observation

/// One result row: the library song and why VYBE picked it.
struct VybeResult: Identifiable, Equatable {
    let song: Song
    let reasons: [String]
    var id: Int64 { song.id }
}

/// What the results answer, for the header above them.
struct VybeResults: Equatable {
    let title: String
    let note: String?
    let songs: [VybeResult]
    var choices: [VybeNameChoice] = []
}

struct VybeNameChoice: Equatable, Identifiable {
    let match: VybeNameMatch
    let query: String
    let wantsSimilar: Bool
    var id: String { match.id }
}

/// The screen's query state.
enum VybeQueryState: Equatable {
    case idle
    case searching(String)
    case done(String, VybeResults)
    case error(String, String)
}

/// VYBE for the screens (Android's VybeViewModel): the engine's status, the running query and its
/// results as library songs. Queries run when submitted, never per keystroke.
@MainActor
@Observable
final class VybeStore {
    static let resultLimit = 30
    private static let weakNote = "These are loose matches. Try a genre or add a little more detail."

    private(set) var status: VybeStatus = .loadingModel
    private(set) var timings = VybeTimings()
    private(set) var query: VybeQueryState = .idle
    var message: String?

    let engine: VybeEngine
    private let database: LibraryDatabase
    private let player: PlayerController
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var retryWhenReady: (() -> Void)?

    init(database: LibraryDatabase, player: PlayerController) {
        self.database = database
        self.player = player
        let box = WeakBox<VybeStore>()
        engine = VybeEngine(database: database) { status, timings in
            Task { @MainActor in
                box.value?.receive(status, timings)
            }
        }
        box.value = self
    }

    private func receive(_ status: VybeStatus, _ timings: VybeTimings) {
        self.status = status
        self.timings = timings
        if case .ready = status {
            let retry = retryWhenReady
            retryWhenReady = nil
            retry?()
        }
    }

    private func afterIndexing(_ retry: @escaping () -> Void) {
        switch status {
        case .loadingModel, .indexing: retryWhenReady = retry
        default: retryWhenReady = nil
        }
    }

    /// Loads the model and indexes, if not already; library changes then re-index (debounced).
    func start() {
        guard !started else { return }
        started = true
        Task { await engine.refresh() }
        observer = NotificationCenter.default.addObserver(forName: SQLiteDatabase.didChange, object: database.db, queue: .main) { [weak self] note in
            guard SQLiteDatabase.affects(note, tables: ["songs", "artist_alias"]) else { return }
            MainActor.assumeIsolated { self?.libraryChanged() }
        }
    }

    private func libraryChanged() {
        pendingRefresh?.cancel()
        let engine = engine
        pendingRefresh = Task {
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
            await engine.refresh()
        }
    }

    /// Runs [text] (submitted).
    func submit(_ text: String) {
        let trimmed = text.trimmed
        if trimmed.isEmpty { return }
        afterIndexing { [weak self] in self?.submit(trimmed) }
        let engine = engine
        run(trimmed) { try await engine.search(trimmed, limit: Self.resultLimit) }
    }

    /// Songs like the playing one.
    func similarToCurrent() {
        guard let song = player.state.currentSong else { return }
        searchSimilar(song.id, title: song.title)
    }

    private func searchSimilar(_ id: Int64, title: String) {
        afterIndexing { [weak self] in self?.searchSimilar(id, title: title) }
        let engine = engine
        run("Like \"\(title)\"") { await engine.similarTo(id, limit: Self.resultLimit) }
    }

    func clear() {
        running?.cancel()
        retryWhenReady = nil
        query = .idle
    }

    func choose(_ choice: VybeNameChoice) {
        afterIndexing { [weak self] in self?.choose(choice) }
        let engine = engine
        run(choice.match.name) {
            await engine.select(choice.match, query: choice.query, wantsSimilar: choice.wantsSimilar, limit: Self.resultLimit)
        }
    }

    func play(_ results: [VybeResult], index: Int) {
        if results.isEmpty { return }
        player.setShuffleModeEnabled(false)
        player.playCollection(results.map(\.song), startIndex: min(max(index, 0), results.count - 1), origin: nil, source: .vybe)
    }

    func shuffle(_ results: [VybeResult]) {
        if results.isEmpty { return }
        player.setShuffleModeEnabled(true)
        player.playCollection(results.map(\.song), startIndex: Int.random(in: 0..<results.count), origin: nil, source: .vybe)
    }

    func addAllToQueue(_ results: [VybeResult]) {
        for result in results { player.addToQueue(result.song) }
        message = "Added \(results.count) songs to the queue"
    }

    private func run(_ label: String, _ answer: @escaping () async throws -> VybeAnswer?) {
        running?.cancel()
        query = .searching(label)
        running = Task {
            let state: VybeQueryState
            do {
                if let result = try await answer() {
                    state = .done(label, present(result))
                } else {
                    state = retryWhenReady == nil ? .error(label, "VYBE isn't ready yet") : .searching(label)
                }
            } catch {
                state = .error(label, error.localizedDescription)
            }
            if !Task.isCancelled { query = state }
        }
    }

    /// Turns an answer into rows of library songs, with a header that says what was matched how.
    private func present(_ answer: VybeAnswer) -> VybeResults {
        switch answer {
        case .named(let kind, let name, let songIds, let similar):
            let named = songs(songIds.map { VybeHit(songId: $0, score: 1, reasons: ["\(Self.label(kind)) match"]) })
            return VybeResults(
                title: "\(Self.label(kind)): \(name)",
                note: similar.isEmpty ? "Found by name in your library."
                    : "Your matches, followed by similar tracks from your library.",
                songs: named + songs(similar)
            )
        case .described(_, let hits, let weak, let unknownName):
            let note = [
                unknownName.map { "No close name match for \"\($0)\". Showing matches by description." },
                "Matched using your library's genres, tempo, artists and saved lyrics.",
                weak ? Self.weakNote : nil,
            ].compactMap { $0 }.joined(separator: " ")
            return VybeResults(title: "Closest in your library", note: note, songs: songs(hits))
        case .similarTo(_, let hits):
            return VybeResults(title: "Like what's playing", note: "Songs with similar styles and tempo.", songs: songs(hits))
        case .ambiguous(let query, let matches, let wantsSimilar):
            return VybeResults(title: matches.isEmpty ? "No matches with these filters" : "Which one did you mean?",
                               note: matches.isEmpty ? nil : "Choose a match, or add more of its name.", songs: [],
                               choices: matches.map { VybeNameChoice(match: $0, query: query, wantsSimilar: wantsSimilar) })
        }
    }

    private func songs(_ hits: [VybeHit]) -> [VybeResult] {
        let found = (try? database.songs(ids: hits.map(\.songId))) ?? []
        let byId = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return hits.compactMap { hit in byId[hit.songId].map { VybeResult(song: $0, reasons: hit.reasons) } }
    }

    private static func label(_ kind: EntityKind) -> String {
        switch kind {
        case .artist: "Artist"
        case .album: "Album"
        case .title: "Title"
        }
    }
}

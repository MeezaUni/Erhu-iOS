import Foundation
import Observation

/// Where a track is in the Fix Tags queue.
enum RepairStatus: String, Codable, Sendable {
    case pending, fixing, done, partial, unchanged, needsReview, noMatch, failed, networkFailed, reverted

    var label: String {
        switch self {
        case .pending: "Waiting"
        case .fixing: "Looking up…"
        case .done: "Fixed"
        case .partial: "Partly fixed"
        case .unchanged: "Unchanged"
        case .needsReview: "Needs review"
        case .noMatch: "No match"
        case .failed: "Failed"
        case .networkFailed: "Couldn't reach the providers"
        case .reverted: "Reverted"
        }
    }

    /// Statuses a run (or a resume) looks up; everything else is finished and never redone.
    var toProcess: Bool { self == .pending || self == .networkFailed }
}

/// What a lookup saw, kept as separate fields so the screen never has to piece text back together.
struct RepairDiagnostics: Sendable {
    var fileName: String
    var identity: TrackIdentity
    var outcomes: [ProviderOutcome] = []
    var candidates: [MetadataCandidate] = []
    var topCandidates: [MetadataCandidate] = []
    var attempts: [QueryAttempt] = []
    var finalReason: String?
}

/// One track in the queue.
struct RepairItem: Identifiable, Sendable {
    var song: Song
    var status: RepairStatus = .pending
    var reason: String?
    var diagnostics: RepairDiagnostics?
    var changes: [FieldFixPlan.Change] = []
    var notes: [String] = []
    /// A copy of the file as it was before the write, for Revert.
    var backup: URL?

    var id: Int64 { song.id }

    var savedCandidates: [MetadataCandidate] {
        guard let diagnostics else { return [] }
        return diagnostics.candidates.isEmpty ? diagnostics.topCandidates : diagnostics.candidates
    }
}

/// Fix Tags: looks up each queued track online, plans the edit for the chosen fields (see
/// [FieldFixPlanner]), writes it with [TagWriter] and keeps the original so it can be reverted.
/// A lookup that couldn't reach any provider pauses the batch rather than counting as "no match".
@MainActor
@Observable
final class FixTagsStore {
    struct Settings: Codable, Equatable {
        var fields: [String] = MetadataField.allCases.filter { $0 != .filename }.map(\.rawValue)
        var source = MetadataSources.all
        var acceptAt: Float = highConfidenceThreshold
        var orderingFieldsVersion = 1

        enum CodingKeys: String, CodingKey { case fields, source, acceptAt, orderingFieldsVersion }
        init() {}
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            fields = try values.decodeIfPresent([String].self, forKey: .fields) ?? fields
            let requested = try values.decodeIfPresent(String.self, forKey: .source) ?? source
            source = MetadataSources.options.first { $0.key.lowercased() == requested.lowercased() }?.key ?? MetadataSources.all
            acceptAt = try values.decodeIfPresent(Float.self, forKey: .acceptAt) ?? acceptAt
            // Add ordering to an existing "all fields" setup once, preserving custom selections.
            if !values.contains(.orderingFieldsVersion), Set(fields).isSuperset(of: MetadataField.fillOnlyTags.map(\.rawValue)) {
                for field in [MetadataField.trackNumber, .discNumber] where !fields.contains(field.rawValue) { fields.append(field.rawValue) }
            }
        }
    }

    private(set) var queue: [RepairItem] = []
    private(set) var isRunning = false
    private(set) var isCheckingMissing = false
    private(set) var missingScanMessage: String?
    private(set) var pauseReason: String?
    private(set) var settings: Settings
    private(set) var autoSelectionProgress: (completed: Int, total: Int)?
    private(set) var autoSelectionMessage: String?
    private(set) var isAutoSelectionPaused = false

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored let service: MetadataService
    @ObservationIgnored private let bpmFinder: BpmFinder
    @ObservationIgnored private let settingsStore = JSONStore<Settings>(name: "fix_tags.json")
    @ObservationIgnored private var pauseRequested = false
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Originals kept for Revert, until the queue is cleared.
    static var backupFolder: URL {
        let url = LibraryPaths.supportFolder.appendingPathComponent("tag-backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    init(library: LibraryStore, service: MetadataService = MetadataService(), bpmFinder: BpmFinder = BpmFinder()) {
        self.library = library
        self.service = service
        self.bpmFinder = bpmFinder
        settings = Settings()
        settings = settingsStore.load() ?? Settings()
        settingsStore.save(settings)
        // Backups of an earlier session belong to a queue that no longer exists.
        try? FileManager.default.removeItem(at: Self.backupFolder)
    }

    var selectedFields: Set<MetadataField> { Set(settings.fields.compactMap(MetadataField.init(rawValue:))) }

    func update(_ edit: (inout Settings) -> Void) {
        edit(&settings)
        settingsStore.save(settings)
    }

    func setField(_ field: MetadataField, _ on: Bool) {
        var fields = selectedFields
        if on { fields.insert(field) } else { fields.remove(field) }
        update { $0.fields = MetadataField.allCases.filter { fields.contains($0) }.map(\.rawValue) }
        missingScanMessage = nil
    }

    var hasWork: Bool { queue.contains { $0.status.toProcess } }
    var revertible: [RepairItem] { queue.filter { $0.backup != nil } }
    var autoCandidateCount: Int { queue.filter { BulkMetadataSelection.canResolve($0) }.count }

    func enqueue(_ songs: [Song]) {
        let present = Set(queue.map(\.id))
        queue += songs.filter { !present.contains($0.id) }.map { RepairItem(song: $0) }
    }

    /// Cached scan for callers that already have complete Song metadata. The UI reads actual tags.
    nonisolated static func incomplete(_ songs: [Song], fields: Set<MetadataField> = Set(MetadataField.allCases)) -> [Song] {
        songs.filter { song in
            let tags = FileTags(title: song.title, artist: song.artist, album: song.album,
                                trackNumber: song.trackNumber, discNumber: song.discNumber, year: song.year,
                                genres: Genres.parse(song.genre), bpmText: song.bpm.map(String.init))
            return !MetadataCompleteness.missing(tags, fields: fields).isEmpty
        }
    }

    func findMissingTags() async {
        guard !isRunning, !isCheckingMissing else { return }
        let fields = selectedFields
        guard !fields.subtracting([.filename]).isEmpty else {
            missingScanMessage = "Choose which tags to check first."
            return
        }
        isCheckingMissing = true
        defer { isCheckingMissing = false }
        let songs = library.songs
        let found = await Task.detached(priority: .utility) {
            songs.compactMap { song -> (Song, [MetadataField])? in
                let missing = MetadataCompleteness.missing(TagReader.read(song.url), fields: fields)
                return missing.isEmpty ? nil : (song, missing)
            }
        }.value
        enqueue(found.map { $0.0 })
        for (song, missing) in found {
            if let index = queue.firstIndex(where: { $0.id == song.id }) {
                queue[index].status = .pending
                queue[index].reason = "Missing: " + missing.map(\.displayName).joined(separator: ", ")
            }
        }
        let labels = MetadataField.allCases.filter { field in found.contains { $0.1.contains(field) } }.map(\.displayName)
        missingScanMessage = found.isEmpty ? "No missing selected tags found." : "Found \(countLabel(found.count, "track")) needing: " + labels.joined(separator: ", ") + "."
    }

    func remove(_ item: RepairItem) {
        guard !isRunning, !isCheckingMissing else { return }
        if let backup = item.backup { try? FileManager.default.removeItem(at: backup) }
        queue.removeAll { $0.id == item.id }
    }

    func retry(_ item: RepairItem) {
        guard let index = queue.firstIndex(where: { $0.id == item.id }), !isRunning, !isCheckingMissing else { return }
        queue[index].status = .pending
        queue[index].reason = nil
    }

    /// Empties the queue and deletes the kept originals (changes can no longer be reverted).
    func clear() {
        guard !isRunning, !isCheckingMissing else { return }
        queue = []
        autoSelectionProgress = nil
        autoSelectionMessage = nil
        isAutoSelectionPaused = false
        pauseReason = nil
        try? FileManager.default.removeItem(at: Self.backupFolder)
    }

    func pause() { pauseRequested = true }

    func start() {
        guard !isRunning, !isCheckingMissing, hasWork else { return }
        let selection = FieldSelection(selectedFields)
        guard !selection.fields.isEmpty else {
            pauseReason = "Choose at least one field to fix"
            return
        }
        isRunning = true
        autoSelectionProgress = nil
        autoSelectionMessage = nil
        isAutoSelectionPaused = false
        pauseRequested = false
        pauseReason = nil
        let source = settings.source
        let acceptAt = settings.acceptAt
        task = Task { [weak self] in
            await self?.run(selection: selection, source: source, acceptAt: acceptAt)
        }
    }

    private func run(selection: FieldSelection, source: String, acceptAt: Float) async {
        var wroteAny = false
        for index in queue.indices where queue[index].status.toProcess {
            if pauseRequested {
                pauseReason = "Paused"
                break
            }
            queue[index].status = .fixing
            queue[index].reason = nil
            let item = queue[index]
            let outcome = await lookUp(item, selection: selection, source: source, acceptAt: acceptAt)
            switch outcome {
            case .unreachable(let reason):
                // The track wasn't checked: it goes back as it was, and the batch waits for the connection.
                queue[index].status = .pending
                pauseReason = "\(reason). Nothing more was looked up; resume when you're back online."
                isRunning = false
                if wroteAny { library.scan() }
                return
            case .concluded(var updated, let plan):
                if let request = plan?.request {
                    updated = await write(request, plan: plan!, item: updated)
                    wroteAny = wroteAny || updated.status == .done || updated.status == .partial
                }
                queue[index] = updated
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        isRunning = false
        if wroteAny { library.scan() }
    }

    private enum Lookup {
        case concluded(RepairItem, FieldFixPlan?)
        case unreachable(String)
    }

    private func lookUp(_ item: RepairItem, selection: FieldSelection, source: String, acceptAt: Float, autoResolve: Bool = false) async -> Lookup {
        var item = item
        let url = item.song.url
        guard FileManager.default.fileExists(atPath: url.path) else {
            item.status = .failed
            item.reason = "The file no longer exists"
            return .concluded(item, nil)
        }
        let embedded = await Task.detached(priority: .utility) { TagReader.read(url) }.value
        let selected = Set(MetadataField.allCases.filter { $0 != .filename && FieldSelection([$0]).fields.isSubset(of: selection.fields) })
        let missing = MetadataCompleteness.missing(embedded, fields: selected)
        if autoResolve && missing.isEmpty {
            item.status = .unchanged
            item.reason = "Selected tags are already complete."
            return .concluded(item, nil)
        }
        let effectiveSelection = autoResolve ? FieldSelection(Set(missing), fillMissingOnly: true) : selection
        let fileName = url.lastPathComponent
        let cleaned = FilenameCleaner.clean(fileName)
        let identity = TrackIdentity(
            title: usableIdentityText(embedded.title) ?? usableIdentityText(item.song.title),
            artist: usableIdentityText(embedded.artist) ?? usableIdentityText(item.song.artist),
            album: usableIdentityText(embedded.album) ?? usableIdentityText(item.song.album),
            durationMs: item.song.durationMs > 0 ? item.song.durationMs : nil,
            fileTitles: TitleCandidates.generate(fileName),
            fileArtist: usableIdentityText(cleaned.artistGuess)
        )
        let service = service
        let result = await TrackMatcher.match(identity, acceptAt: acceptAt, allowBestCandidate: autoResolve) { query in
            let artist = query.artist.flatMap { $0.lowercased() == query.title.lowercased() ? nil : $0 }
            return await service.search(title: query.title, artist: artist, album: query.album, durationMs: identity.durationMs, selection: source)
        }
        var candidates = result.candidates
        if autoResolve {
            let liveIDs = Set(candidates.map(\.id))
            let query = TrackQuery(title: identity.title ?? identity.fileTitles.first ?? item.song.title, artist: identity.artist ?? identity.fileArtist, source: .tag, album: identity.album)
            candidates += item.savedCandidates.filter { !liveIDs.contains($0.id) }.map { TrackMatcher.rescore($0, identity, query) }
        }
        var diagnostics = RepairDiagnostics(fileName: fileName, identity: identity, outcomes: result.outcomes,
                                            candidates: candidates,
                                            topCandidates: Array(candidates.sorted { $0.confidenceScore > $1.confidenceScore }.prefix(3)), attempts: result.attempts)
        func concluded(_ status: RepairStatus, _ reason: String?, _ plan: FieldFixPlan? = nil) -> Lookup {
            diagnostics.finalReason = reason
            item.status = status
            item.reason = reason
            item.diagnostics = diagnostics
            return .concluded(item, plan)
        }
        let chosen: MetadataCandidate?
        if autoResolve {
            var review = item
            review.status = .needsReview
            review.diagnostics = diagnostics
            chosen = BulkMetadataSelection.best(for: review, minimumConfidence: acceptAt)
        } else if case .confident(let match) = result.decision { chosen = match }
        else { chosen = nil }
        if let match = chosen {
            let plan = await planFix(match, candidates: candidates, local: embedded, song: item.song, url: url,
                                     selection: effectiveSelection, acceptAt: acceptAt)
            item.changes = plan.changes
            item.notes = plan.notes
            if plan.request == nil {
                // Nothing to write is not a fix: say why instead of reporting success.
                return concluded(plan.unfilled.isEmpty ? .unchanged : .needsReview, plan.unfilled.isEmpty ? "Selected tags are already complete." : "Still missing: " + plan.unfilled.joined(separator: ", ") + ". See details for lookup results.")
            }
            return concluded(.fixing, nil, plan)
        }
        switch Self.networkVerdict(result.outcomes) {
        case .unreachable(let reason): return .unreachable(reason)
        case .partly(let reason): return concluded(.networkFailed, reason)
        case nil: break
        }
        switch result.decision {
        case .noMatch(let reason):
            if result.candidates.isEmpty, let failure = Self.providerFailureSummary(result.outcomes) {
                return concluded(.failed, failure)
            }
            return concluded(.noMatch, reason ?? "No online match found")
        case .lowConfidence(_, let reason), .ambiguous(_, let reason):
            return concluded(.needsReview, reason)
        case .confident:
            return concluded(.needsReview, "No sufficiently verified identity for the remaining fields. Enter known tags manually.")
        }
    }

    /// Plans the edit for a confident match: looks up a genre, a date and a BPM only when the
    /// selection could use them; lookup failures become notes (and "unfilled" reasons), never empty values.
    private func planFix(_ match: MetadataCandidate, candidates: [MetadataCandidate], local embedded: FileTags, song: Song, url: URL,
                         selection: FieldSelection, acceptAt: Float) async -> FieldFixPlan {
        let fields = selection.fields
        let fillOnly = selection.fillOnly
        let local = LocalTrackTags(
            title: embedded.title ?? "", artist: embedded.artist ?? "", album: embedded.album ?? "",
            genre: Genres.join(embedded.genres), hasArtwork: embedded.hasArtwork, tagsReadable: true,
            year: embedded.dateText ?? embedded.year.map(String.init), bpm: embedded.bpmText,
            trackNumber: embedded.trackNumber, discNumber: embedded.discNumber
        )
        var reasons: [String: String] = [:]
        var sourceNotes: [String] = []
        let verified = MetadataEnrichment.verified(match, candidates: candidates, acceptAt: acceptAt)
        var albumMatch = match
        if isUsableTag(local.album), fillOnly || !fields.contains(.album),
           let sameAlbum = verified.first(where: { MetadataEnrichment.releaseKey($0.album) == MetadataEnrichment.releaseKey(local.album) }) {
            albumMatch = sameAlbum
        } else if !isUsableTag(match.album), let knownAlbum = verified.first(where: { isUsableTag($0.album) }) {
            albumMatch = knownAlbum
            sourceNotes.append("Album from " + knownAlbum.sourceName)
        }
        var genre: String?
        if fields.contains(.genre) && (!fillOnly || !isUsableTag(local.genre)) {
            switch await service.lookupGenre(match, candidates: candidates, acceptAt: acceptAt) {
            case .found(let genres, let source):
                genre = Genres.join(genres)
                sourceNotes.append("Genre from " + source)
            case .notFound(let reason): reasons["No genre found online"] = "No genre: \(reason)"
            case .failed(let reason): reasons["No genre found online"] = "Genre lookup failed: \(reason)"
            }
        }
        var releaseDate: ReleaseDate?
        if fields.contains(.year) && (!fillOnly || !isUsableYearTag(local.year)) {
            switch MetadataEnrichment.releaseDate(albumMatch, candidates: candidates, acceptAt: acceptAt) {
            case .found(let date): releaseDate = date
            case .rejected(let reason): reasons["No release year found online"] = "No year: \(reason)"
            }
        }
        var bpm: FoundBpm?
        if fields.contains(.bpm) && usableBpm(local.bpm) == nil {
            var tempoMatches = verified
            if let index = tempoMatches.firstIndex(where: { $0.sourceName == MetadataSources.deezer }) {
                let (enriched, note) = await service.withReportedTempo(tempoMatches[index])
                tempoMatches[index] = enriched
                if let note { sourceNotes.append(note) }
            }
            let tempoMatch = tempoMatches.first(where: { $0.id == match.id }) ?? match
            switch await bpmFinder.find(tempoMatch, file: url, supporting: tempoMatches) {
            case .found(let found): bpm = found
            case .notFound(let reason): reasons["No BPM found"] = "No BPM: \(reason)"
            case .failed(let reason): reasons["No BPM found"] = "BPM lookup failed: \(reason)"
            }
        }
        var positioned = albumMatch
        var positionNote: String?
        if (fields.contains(.trackNumber) && (!fillOnly || (local.trackNumber ?? 0) <= 0))
            || (fields.contains(.discNumber) && (!fillOnly || (local.discNumber ?? 0) <= 0)) {
            (positioned, positionNote) = await service.bestAlbumPosition(albumMatch, candidates: candidates, acceptAt: acceptAt,
                localTrack: fillOnly || !fields.contains(.trackNumber) ? local.trackNumber : nil,
                localDisc: fillOnly || !fields.contains(.discNumber) ? local.discNumber : nil)
        }
        var plan = FieldFixPlanner.plan(fields: fields, fillOnly: fillOnly, local: local, match: positioned, genre: genre,
                                        artwork: nil, releaseDate: releaseDate, bpm: bpm)
        plan.notes = plan.notes.map { reasons[$0] ?? $0 }
        plan.notes += sourceNotes
        if let positionNote { plan.notes.append(positionNote) }
        plan.checkedFields = Set(MetadataField.allCases.filter {
            $0 != .filename && FieldSelection([$0]).fields.isSubset(of: fields)
        })
        let after = MetadataCompleteness.applying(plan.request, to: embedded)
        plan.unfilled = MetadataCompleteness.missing(after, fields: plan.checkedFields).map(\.displayName)
        return plan
    }

    /// Writes the planned edit, keeping the original for Revert. A track is marked fixed only once
    /// its file was actually written.
    private func write(_ request: TagWriteRequest, plan: FieldFixPlan, item: RepairItem) async -> RepairItem {
        var item = item
        let url = item.song.url
        let previousBackup = item.backup
        let backup = previousBackup ?? Self.backupFolder.appendingPathComponent("\(UUID().uuidString).\(url.pathExtension)")
        do {
            let written = try await Task.detached(priority: .utility) {
                if previousBackup == nil { try FileManager.default.copyItem(at: url, to: backup) }
                do {
                    try TagWriter.write(request, to: url)
                } catch {
                    if previousBackup == nil { try? FileManager.default.removeItem(at: backup) }
                    throw error
                }
                return TagReader.read(url)
            }.value
            ArtworkLoader.shared.forget(path: url.path)
            item.backup = backup
            let remaining = MetadataCompleteness.missing(written, fields: plan.checkedFields).map(\.displayName)
            item.status = remaining.isEmpty ? .done : .partial
            item.reason = remaining.isEmpty ? nil : "Still missing: " + remaining.joined(separator: ", ")
        } catch {
            item.status = .failed
            item.reason = error.localizedDescription
        }
        return item
    }

    /// Writes [match], picked by the listener for a track that needed review (or had no confident
    /// match), with the same plan and backup as an automatic fix.
    func apply(_ match: MetadataCandidate, to id: Int64) async {
        guard !isRunning, !isCheckingMissing else { return }
        autoSelectionProgress = nil
        autoSelectionMessage = nil
        isRunning = true
        defer { isRunning = false }
        if await applyOne(match, to: id, selection: FieldSelection(selectedFields), acceptAt: settings.acceptAt) { library.scan() }
    }

    /// One tap refreshes unresolved tracks and fills selected missing fields from verified sources.
    func autoSelectBestCandidates() {
        guard !isRunning, !isCheckingMissing else { return }
        let choices = queue.filter { BulkMetadataSelection.canResolve($0) }.map(\.id)
        guard !choices.isEmpty else { autoSelectionMessage = "No unresolved tracks in this queue. Find missing tags or add songs first."; return }
        let selection = FieldSelection(selectedFields)
        guard !selection.fields.isEmpty else { pauseReason = "Choose which fields to fix first."; return }
        let acceptAt = settings.acceptAt
        isRunning = true
        pauseRequested = false
        pauseReason = nil
        isAutoSelectionPaused = false
        autoSelectionMessage = nil
        autoSelectionProgress = (0, choices.count)
        task = Task { [weak self] in
            guard let self else { return }
            var written = 0
            for (index, choice) in choices.enumerated() {
                if pauseRequested {
                    isAutoSelectionPaused = true
                    pauseReason = "Paused. Use Auto-fill best available tags to continue with the remaining tracks."
                    break
                }
                guard let row = queue.firstIndex(where: { $0.id == choice }) else { continue }
                let before = queue[row]
                queue[row].status = .fixing
                switch await lookUp(before, selection: selection, source: MetadataSources.all, acceptAt: acceptAt, autoResolve: true) {
                case .unreachable(let reason):
                    queue[row] = before
                    queue[row].status = .networkFailed
                    queue[row].reason = reason + ". Enter known missing tags manually, or retry online."
                case .concluded(var updated, let plan):
                    if let request = plan?.request {
                        updated = await write(request, plan: plan!, item: updated)
                        if updated.status == .done || updated.status == .partial { written += 1 }
                    }
                    queue[row] = updated
                }
                autoSelectionProgress = (index + 1, choices.count)
            }
            let remaining = queue.filter { BulkMetadataSelection.canResolve($0) && $0.status != .unchanged }.count
            autoSelectionMessage = written > 0
                ? "Updated \(countLabel(written, "track")); \(remaining) still have unresolved tags. Open an unfinished track to enter known values manually."
                : "No tags changed. Selected fields are either complete or no reliable value was available. Open an unfinished track to enter known values manually."
            isRunning = false
            if written > 0 { library.scan() }
        }
    }

    private func applyOne(_ match: MetadataCandidate, to id: Int64, selection: FieldSelection, acceptAt: Float) async -> Bool {
        guard let start = queue.firstIndex(where: { $0.id == id }) else { return false }
        var item = queue[start]
        item.status = .fixing
        queue[start] = item
        let url = item.song.url
        guard FileManager.default.fileExists(atPath: url.path) else {
            queue[start].status = .failed
            queue[start].reason = "The file no longer exists"
            return false
        }
        let embedded = await Task.detached(priority: .utility) { TagReader.read(url) }.value
        let plan = await planFix(match, candidates: item.savedCandidates, local: embedded, song: item.song, url: url,
                                 selection: selection, acceptAt: acceptAt)
        item.changes = plan.changes
        item.notes = plan.notes
        if let request = plan.request {
            item = await write(request, plan: plan, item: item)
        } else {
            item.status = plan.unfilled.isEmpty ? .unchanged : .needsReview
            item.reason = plan.unfilled.isEmpty ? "Selected tags are already complete." : "Still missing: " + plan.unfilled.joined(separator: ", ")
        }
        if let index = queue.firstIndex(where: { $0.id == id }) { queue[index] = item }
        return item.status == .done || item.status == .partial
    }

    /// Manual values share the same original backup and update the queue from the file after saving.
    func saveManual(_ request: TagWriteRequest, to id: Int64, checkedFields: Set<MetadataField>) async throws {
        guard !isRunning, !isCheckingMissing else { throw TagWriteError.io("Wait for the current tag operation to finish") }
        guard let index = queue.firstIndex(where: { $0.id == id }) else { throw TagWriteError.io("This track is no longer in the queue") }
        isRunning = true
        autoSelectionProgress = nil
        defer { isRunning = false }
        let plan = FieldFixPlan(request: request, changes: [], notes: ["Known values entered manually"], checkedFields: checkedFields)
        var updated = await write(request, plan: plan, item: queue[index])
        updated.notes.append("Known values entered manually")
        queue[index] = updated
        if updated.status == .failed { throw TagWriteError.io(updated.reason ?? "The tags could not be saved") }
        library.scan()
    }

    /// Puts the selected tracks' files back exactly as they were before their fix.
    func revert(_ ids: Set<Int64>) async {
        guard !isRunning, !isCheckingMissing else { return }
        var count = 0
        for index in queue.indices where ids.contains(queue[index].id) {
            guard let backup = queue[index].backup else { continue }
            let url = queue[index].song.url
            do {
                try await Task.detached(priority: .utility) {
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: backup)
                }.value
                ArtworkLoader.shared.forget(path: url.path)
                queue[index].backup = nil
                queue[index].status = .reverted
                queue[index].reason = nil
                count += 1
            } catch {
                queue[index].reason = "Couldn't revert: \(error.localizedDescription)"
            }
        }
        if count > 0 { library.scan() }
    }

    enum NetworkVerdict: Equatable {
        case unreachable(String)
        case partly(String)
    }

    /// If a provider couldn't be reached, the track is not "no match"; nil when every queried provider answered.
    nonisolated static func networkVerdict(_ outcomes: [ProviderOutcome]) -> NetworkVerdict? {
        let unreachable = outcomes.filter { $0.status.isTransient }
        guard !unreachable.isEmpty else { return nil }
        let reason = unreachable.map { "\($0.providerName): \($0.errorMessage ?? $0.status.label)" }.joined(separator: "; ")
        return outcomes.contains { $0.status.answered } ? .partly(reason) : .unreachable(reason)
    }

    /// When every provider that was asked failed rather than answered, the failures.
    nonisolated static func providerFailureSummary(_ outcomes: [ProviderOutcome]) -> String? {
        let considered = outcomes.filter { $0.status != .skipped }
        let failed = considered.filter { !$0.status.answered }
        if considered.isEmpty { return "No provider could be queried for this source" }
        guard failed.count == considered.count else { return nil }
        return "Lookup failed: " + failed.map { "\($0.providerName): \($0.errorMessage ?? $0.status.label)" }.joined(separator: "; ")
    }
}

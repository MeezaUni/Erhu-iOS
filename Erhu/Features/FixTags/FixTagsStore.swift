import Foundation
import Observation

/// Where a track is in the Fix Tags queue.
enum RepairStatus: String, Codable, Sendable {
    case pending, fixing, done, partial, unchanged, needsReview, noMatch, failed, networkFailed, reverted

    var label: String {
        switch self {
        case .pending: String(localized: "Waiting")
        case .fixing: String(localized: "Looking up…")
        case .done: String(localized: "Fixed")
        case .partial: String(localized: "Needs review")
        case .unchanged: String(localized: "Unchanged")
        case .needsReview: String(localized: "Needs review")
        case .noMatch: String(localized: "No match")
        case .failed: String(localized: "Failed")
        case .networkFailed: String(localized: "Couldn't reach the providers")
        case .reverted: String(localized: "Reverted")
        }
    }

    /// Statuses a run (or a resume) looks up; everything else is finished and never redone.
    var toProcess: Bool { self == .pending || self == .networkFailed }
}

/// What a lookup saw, kept as separate fields so the screen never has to piece text back together.
struct RepairDiagnostics: Codable, Sendable {
    var fileName: String
    var identity: TrackIdentity
    var outcomes: [ProviderOutcome] = []
    var candidates: [MetadataCandidate] = []
    var topCandidates: [MetadataCandidate] = []
    var attempts: [QueryAttempt] = []
    var finalReason: String?
}

/// One track in the queue.
struct RepairItem: Identifiable, Codable, Sendable {
    var song: Song
    var status: RepairStatus = .pending
    var reason: String?
    var diagnostics: RepairDiagnostics?
    var changes: [FieldFixPlan.Change] = []
    var notes: [String] = []
    /// Values found online, held until every selected field can be completed together.
    var proposedRequest: TagWriteRequest?
    var proposedFields: Set<MetadataField> = []
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
    private(set) var inPlaceScope = Set<Int64>()
    private(set) var isRunning = false
    private(set) var isCheckingMissing = false
    private(set) var missingScanMessage: String?
    private(set) var hasMissingScanProgress = false
    private(set) var missingScanProgress: (completed: Int, total: Int)?
    @ObservationIgnored private var stopMissingScanRequested = false
    private(set) var pauseReason: String?
    private(set) var settings: Settings
    private(set) var autoSelectionProgress: (completed: Int, total: Int)?
    private(set) var autoSelectionMessage: String?
    private(set) var isAutoSelectionPaused = false

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored let service: MetadataService
    @ObservationIgnored private let bpmFinder: BpmFinder
    @ObservationIgnored private let settingsStore = JSONStore<Settings>(name: "fix_tags.json")
    @ObservationIgnored private let progress: FixTagsProgress
    @ObservationIgnored private var libraryChecked: [Int64: String] = [:]
    @ObservationIgnored private var followsLibrary = false
    @ObservationIgnored private var autoFillRemaining: [Int64]?
    private(set) var hasSavedProgress = false
    @ObservationIgnored private var pauseRequested = false
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Originals kept for Revert, until the queue is cleared.
    static var backupFolder: URL {
        let url = LibraryPaths.supportFolder.appendingPathComponent("tag-backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    init(library: LibraryStore, service: MetadataService = MetadataService(), bpmFinder: BpmFinder = BpmFinder(), checkpointURL: URL? = LibraryPaths.supportFolder.appendingPathComponent("fix-tags-progress.json")) {
        self.library = library
        progress = FixTagsProgress(manifest: ProgressFile(url: checkpointURL))
        self.service = service
        self.bpmFinder = bpmFinder
        settings = Settings()
        settings = settingsStore.load() ?? Settings()
        settingsStore.save(settings)
        if let saved = progress.manifest.load(), saved.version == 1 {
            libraryChecked = saved.libraryChecked
            followsLibrary = saved.followsLibrary
            hasSavedProgress = saved.started
            autoFillRemaining = saved.autoFillRemaining
            inPlaceScope = saved.scope
            hasMissingScanProgress = saved.missingScanInProgress
            missingScanProgress = (saved.missingChecked, saved.missingTotal)
            queue = saved.songs.map { song in
                var item = progress.item(song.id).load() ?? RepairItem(song: song)
                if let current = try? library.database.song(id: song.id) {
                    if current.path != song.path { return RepairItem(song: current) }
                    item.song = current
                }
                if item.status == .fixing { item.status = .pending }
                if let backup = item.backup {
                    let local = Self.backupFolder.appendingPathComponent(backup.lastPathComponent)
                    item.backup = FileManager.default.fileExists(atPath: local.path) ? local : nil
                }
                return item
            }
            isAutoSelectionPaused = !(autoFillRemaining?.isEmpty ?? true)
            if hasSavedProgress { pauseReason = "Saved progress restored. Continue with the remaining tracks; completed tracks are skipped." }
        }
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

    var hasWork: Bool {
        if queue.contains(where: { $0.status.toProcess }) { return true }
        return followsLibrary && library.songs.contains { libraryChecked[$0.id] != $0.path }
    }

    private func saveProgress(_ item: RepairItem? = nil, manifest: Bool = true) {
        do {
            if let item { try progress.item(item.id).save(item) }
            if manifest {
                try progress.manifest.save(.init(songs: queue.map(\.song), libraryChecked: libraryChecked, followsLibrary: followsLibrary,
                                                 started: hasSavedProgress, autoFillRemaining: autoFillRemaining, scope: inPlaceScope,
                                                 missingScanInProgress: hasMissingScanProgress,
                                                 missingChecked: missingScanProgress?.completed ?? 0, missingTotal: missingScanProgress?.total ?? 0))
            }
        } catch {
            pauseRequested = true
            pauseReason = "Couldn’t save progress: \(error.localizedDescription). The run will pause."
        }
    }
    var revertible: [RepairItem] { queue.filter { $0.backup != nil } }
    var autoCandidateCount: Int { queue.filter { BulkMetadataSelection.canResolve($0) }.count }

    func enqueue(_ songs: [Song]) {
        var present = Set(queue.map(\.id))
        let added = songs.filter { present.insert($0.id).inserted }.map { RepairItem(song: $0) }
        queue += added
        saveProgress()
        for item in added { saveProgress(item, manifest: false) }
    }

    /// An in-place action owns only these songs; existing unrelated queue entries stay untouched.
    @discardableResult
    func fixInPlace(_ songs: [Song]) -> Bool {
        guard !isRunning, !isCheckingMissing, !songs.isEmpty else { return false }
        enqueue(songs)
        let ids = Set(songs.map(\.id))
        for index in queue.indices where ids.contains(queue[index].id) {
            queue[index].status = .pending
            queue[index].reason = nil
            saveProgress(queue[index], manifest: false)
        }
        inPlaceScope = ids
        start(scope: ids)
        return isRunning
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
        settingsStore.saveNow(settings)
        followsLibrary = true; inPlaceScope = []; hasSavedProgress = true
        isCheckingMissing = true; hasMissingScanProgress = true; stopMissingScanRequested = false
        defer { isCheckingMissing = false }
        let songs = library.songs
        let keys = fields.map(\.rawValue).sorted()
        missingScanProgress = (missingScanProgress?.completed ?? 0, songs.count)
        saveProgress()
        let progress = self.progress
        let work = await Task.detached(priority: .utility) {
            songs.map { song -> FixTagsProgress.MissingWork in
                let stamp = ProgressFileStamp(song)
                let cached = progress.missing(song.id).load().flatMap {
                    $0.song.path == song.path && $0.stamp == stamp && $0.fields == keys ? $0 : nil
                }
                return FixTagsProgress.MissingWork(song: song, stamp: stamp, cached: cached)
            }
        }.value
        guard !Task.isCancelled, !stopMissingScanRequested else { return }
        var found: [(Song, [MetadataField])] = []
        for entry in work where entry.cached != nil {
            let song = entry.song, check = entry.cached!
            libraryChecked[song.id] = song.path
            if !check.missing.isEmpty {
                found.append((song, check.missing))
                // Recover a result saved just before a force-quit, but never reset an
                // existing completed/reviewed queue item while resuming the file check.
                if !queue.contains(where: { $0.id == song.id }) {
                    let item = RepairItem(song: song, reason: "Missing: " + check.missing.map(\.displayName).joined(separator: ", "))
                    queue.append(item)
                    saveProgress(item, manifest: false)
                }
            }
        }
        var completed = work.filter { $0.cached != nil }.count
        missingScanProgress = (completed, songs.count)
        saveProgress()
        for entry in work where entry.cached == nil {
            guard !Task.isCancelled, !stopMissingScanRequested else { break }
            let song = entry.song
            let check = await Task.detached(priority: .utility) {
                FixTagsProgress.MissingCheck(song: song, stamp: entry.stamp, fields: keys,
                                             missing: MetadataCompleteness.missing(TagReader.read(song.url), fields: fields))
            }.value
            guard !Task.isCancelled, !stopMissingScanRequested else { break }
            do { try progress.missing(song.id).save(check) }
            catch { missingScanMessage = "Couldn’t save tag-check progress: \(error.localizedDescription)"; return }
            libraryChecked[song.id] = song.path
            if !check.missing.isEmpty {
                found.append((song, check.missing))
                let index: Int
                if let existing = queue.firstIndex(where: { $0.id == song.id }) { index = existing }
                else { queue.append(RepairItem(song: song)); index = queue.count - 1 }
                queue[index].diagnostics = nil
                queue[index].proposedRequest = nil
                queue[index].proposedFields = []
                queue[index].changes = []
                queue[index].notes = []
                queue[index].status = .pending
                queue[index].reason = "Missing: " + check.missing.map(\.displayName).joined(separator: ", ")
                saveProgress(queue[index], manifest: false)
            }
            completed += 1
            missingScanProgress = (completed, songs.count)
            saveProgress()
        }
        hasMissingScanProgress = (missingScanProgress?.completed ?? 0) < songs.count
        saveProgress()
        let labels = MetadataField.allCases.filter { field in found.contains { $0.1.contains(field) } }.map(\.displayName)
        missingScanMessage = hasMissingScanProgress ? "Check stopped. Continue checking missing tags to skip completed files and include new songs."
            : found.isEmpty ? "No missing selected tags found." : "Found \(countLabel(found.count, .track)) needing: " + labels.joined(separator: ", ") + "."
    }

    func stopMissingScan() { stopMissingScanRequested = true }

    func remove(_ item: RepairItem) {
        guard !isRunning, !isCheckingMissing else { return }
        if let backup = item.backup { try? FileManager.default.removeItem(at: backup) }
        queue.removeAll { $0.id == item.id }
        autoFillRemaining?.removeAll { $0 == item.id }
        saveProgress()
        progress.item(item.id).remove()
    }

    func retry(_ item: RepairItem) {
        guard let index = queue.firstIndex(where: { $0.id == item.id }), !isRunning, !isCheckingMissing else { return }
        queue[index].status = .pending
        queue[index].reason = nil
        saveProgress(queue[index])
    }

    /// Empties the queue and deletes the kept originals (changes can no longer be reverted).
    func clear() {
        guard !isRunning, !isCheckingMissing else { return }
        queue = []
        inPlaceScope = []
        followsLibrary = false
        libraryChecked = [:]
        hasMissingScanProgress = false
        missingScanProgress = nil
        hasSavedProgress = false
        autoFillRemaining = nil
        progress.clear()
        autoSelectionProgress = nil
        autoSelectionMessage = nil
        isAutoSelectionPaused = false
        pauseReason = nil
        try? FileManager.default.removeItem(at: Self.backupFolder)
    }

    func pause() { pauseRequested = true }

    func start(scope: Set<Int64>? = nil) {
        guard !isRunning, !isCheckingMissing, hasWork else { return }
        if scope == nil { inPlaceScope = [] }
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
        hasSavedProgress = true
        settingsStore.saveNow(settings)
        saveProgress()
        task = Task { [weak self] in
            await self?.run(selection: selection, source: source, acceptAt: acceptAt, scope: scope)
        }
    }

    private func appendNewLibrarySongs() async {
        let newSongs = library.songs.filter { libraryChecked[$0.id] != $0.path }
        let fields = selectedFields
        let missing = await Task.detached(priority: .utility) {
            newSongs.filter { !MetadataCompleteness.missing(TagReader.read($0.url), fields: fields).isEmpty }
        }.value
        for song in newSongs { libraryChecked[song.id] = song.path }
        enqueue(missing)
        hasMissingScanProgress = false
        saveProgress()
    }

    private func run(selection: FieldSelection, source: String, acceptAt: Float, scope: Set<Int64>? = nil) async {
        if scope == nil, followsLibrary { await appendNewLibrarySongs() }
        var wroteAny = false
        for index in queue.indices where queue[index].status.toProcess && (scope == nil || scope!.contains(queue[index].id)) {
            if pauseRequested {
                pauseReason = pauseReason ?? "Paused"
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
                    wroteAny = wroteAny || updated.status == .done
                }
                queue[index] = updated
                saveProgress(updated, manifest: false)
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
        item.proposedRequest = nil
        item.proposedFields = []
        item.changes = []
        item.notes = []
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
            var plan = await planFix(match, candidates: candidates, local: embedded, song: item.song, url: url,
                                     selection: effectiveSelection, acceptAt: acceptAt, catalogueSource: source)
            plan.checkedFields = selected
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
                         selection: FieldSelection, acceptAt: Float, catalogueSource: String = MetadataSources.all) async -> FieldFixPlan {
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
        let searchITunes = MetadataSources.matches(MetadataSources.iTunes, catalogueSource)
        let verified = MetadataEnrichment.verified(match, candidates: candidates, acceptAt: acceptAt)
        var albumMatch = match
        if isUsableTag(local.album), fillOnly || !fields.contains(.album),
           let sameAlbum = verified.first(where: { MetadataEnrichment.releaseKey($0.album) == MetadataEnrichment.releaseKey(local.album) }) {
            albumMatch = sameAlbum
        } else if !isUsableTag(match.album), let knownAlbum = verified.first(where: { isUsableTag($0.album) }) {
            albumMatch = knownAlbum
            sourceNotes.append("Album from " + knownAlbum.sourceName)
        }
        if isUsableTag(local.album), fillOnly || !fields.contains(.album),
           MetadataEnrichment.releaseKey(albumMatch.album) != MetadataEnrichment.releaseKey(local.album),
           (fields.contains(.discNumber) && (local.discNumber ?? 0) <= 0)
            || (fields.contains(.trackNumber) && (local.trackNumber ?? 0) <= 0),
           let recovered = await service.matchingAlbum(match, candidates: candidates, album: local.album, acceptAt: acceptAt, searchITunes: searchITunes) {
            albumMatch = recovered
            sourceNotes.append("Recovered the tagged album from " + recovered.sourceName)
        }
        var genre: String?
        if fields.contains(.genre) && (!fillOnly || !isUsableTag(local.genre)) {
            switch await service.lookupGenre(albumMatch, candidates: candidates, acceptAt: acceptAt, searchITunes: searchITunes) {
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
                localDisc: fillOnly || !fields.contains(.discNumber) ? local.discNumber : nil,
                needsTrack: fields.contains(.trackNumber) && (!fillOnly || (local.trackNumber ?? 0) <= 0))
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
        let before = await Task.detached(priority: .utility) { TagReader.read(url) }.value
        let missing = MetadataCompleteness.missing(MetadataCompleteness.applying(request, to: before), fields: plan.checkedFields)
        guard missing.isEmpty else {
            item.status = .needsReview
            item.reason = "No tags changed. Still missing: " + missing.map(\.displayName).joined(separator: ", ")
            item.proposedRequest = request
            item.proposedFields = plan.checkedFields
            return item
        }
        let previousBackup = item.backup
        let backup = previousBackup ?? Self.backupFolder.appendingPathComponent("\(UUID().uuidString).\(url.pathExtension)")
        do {
            if previousBackup == nil {
                try await Task.detached(priority: .utility) { try FileManager.default.copyItem(at: url, to: backup) }.value
                item.backup = backup
                do { try progress.item(item.id).save(item) }
                catch { try? FileManager.default.removeItem(at: backup); throw error }
            }
            let written = try await Task.detached(priority: .utility) {
                do {
                    try TagWriter.write(request, to: url, requiringComplete: plan.checkedFields)
                } catch {
                    if previousBackup == nil { try? FileManager.default.removeItem(at: backup) }
                    throw error
                }
                return TagReader.read(url)
            }.value
            ArtworkLoader.shared.forget(path: url.path)
            item.backup = backup
            let remaining = MetadataCompleteness.missing(written, fields: plan.checkedFields).map(\.displayName)
            item.status = remaining.isEmpty ? .done : .needsReview
            item.reason = remaining.isEmpty ? nil : "The file changed after verification. Still missing: " + remaining.joined(separator: ", ")
            item.proposedRequest = nil
            item.proposedFields = []
        } catch {
            if previousBackup == nil { item.backup = nil }
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
        inPlaceScope = []
        let selection = FieldSelection(selectedFields)
        guard !selection.fields.isEmpty else { pauseReason = "Choose which fields to fix first."; return }
        let acceptAt = settings.acceptAt
        isRunning = true
        pauseRequested = false
        pauseReason = nil
        isAutoSelectionPaused = false
        autoSelectionMessage = nil
        autoSelectionProgress = nil
        hasSavedProgress = true
        settingsStore.saveNow(settings)
        saveProgress()
        task = Task { [weak self] in
            guard let self else { return }
            if followsLibrary, inPlaceScope.isEmpty { await appendNewLibrarySongs() }
            let resumable = autoFillRemaining.map(Set.init)
            let choices = queue.filter { BulkMetadataSelection.canResolve($0) &&
                (resumable == nil || resumable!.contains($0.id) || $0.status == .pending) }.map(\.id)
            guard !choices.isEmpty else {
                autoSelectionMessage = "No unresolved tracks in this queue. Find missing tags or add songs first."
                autoFillRemaining = nil; saveProgress(); isRunning = false
                return
            }
            autoSelectionProgress = (0, choices.count)
            autoFillRemaining = choices
            saveProgress()
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
                        if updated.status == .done { written += 1 }
                    }
                    queue[row] = updated
                }
                if queue[row].status != .networkFailed { autoFillRemaining?.removeAll { $0 == choice } }
                saveProgress(queue[row])
                autoSelectionProgress = (index + 1, choices.count)
            }
            if autoFillRemaining?.isEmpty == true { autoFillRemaining = nil }
            isAutoSelectionPaused = !(autoFillRemaining?.isEmpty ?? true)
            saveProgress()
            let remaining = queue.filter { BulkMetadataSelection.canResolve($0) && $0.status != .unchanged }.count
            autoSelectionMessage = written > 0
                ? "Fully fixed \(countLabel(written, .track)); \(remaining) still need review. Incomplete repairs were not written."
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
            saveProgress(queue[start], manifest: false)
            return false
        }
        let embedded = await Task.detached(priority: .utility) { TagReader.read(url) }.value
        let plan = await planFix(match, candidates: item.savedCandidates, local: embedded, song: item.song, url: url,
                                 selection: selection, acceptAt: acceptAt, catalogueSource: settings.source)
        item.changes = plan.changes
        item.notes = plan.notes
        if let request = plan.request {
            item = await write(request, plan: plan, item: item)
        } else {
            item.status = plan.unfilled.isEmpty ? .unchanged : .needsReview
            item.reason = plan.unfilled.isEmpty ? "Selected tags are already complete." : "Still missing: " + plan.unfilled.joined(separator: ", ")
        }
        if let index = queue.firstIndex(where: { $0.id == id }) { queue[index] = item }
        saveProgress(item, manifest: false)
        return item.status == .done
    }

    /// Manual values share the same original backup and update the queue from the file after saving.
    func saveManual(_ request: TagWriteRequest, to id: Int64, checkedFields: Set<MetadataField>) async throws {
        guard !isRunning, !isCheckingMissing else { throw TagWriteError.io("Wait for the current tag operation to finish") }
        guard let index = queue.firstIndex(where: { $0.id == id }) else { throw TagWriteError.io("This track is no longer in the queue") }
        isRunning = true
        autoSelectionProgress = nil
        defer { isRunning = false }
        var combined = queue[index].proposedRequest ?? TagWriteRequest()
        combined.title = request.title ?? combined.title
        combined.artist = request.artist ?? combined.artist
        combined.album = request.album ?? combined.album
        combined.releaseDate = request.releaseDate ?? combined.releaseDate
        combined.year = request.year ?? combined.year
        combined.genre = request.genre ?? combined.genre
        combined.bpm = request.bpm ?? combined.bpm
        combined.trackNumber = request.trackNumber ?? combined.trackNumber
        combined.discNumber = request.discNumber ?? combined.discNumber
        let fields = checkedFields.union(queue[index].proposedFields)
        let plan = FieldFixPlan(request: combined, changes: [], notes: ["Known values entered manually"], checkedFields: fields)
        var updated = await write(combined, plan: plan, item: queue[index])
        updated.notes.append("Known values entered manually")
        queue[index] = updated
        saveProgress(updated, manifest: false)
        if updated.status == .failed { throw TagWriteError.io(updated.reason ?? "The tags could not be saved") }
        if updated.status == .needsReview { throw TagWriteError.io(updated.reason ?? "Complete the remaining selected tags before saving") }
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
                queue[index].proposedRequest = nil
                queue[index].proposedFields = []
                saveProgress(queue[index], manifest: false)
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

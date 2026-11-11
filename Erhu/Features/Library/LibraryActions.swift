import Foundation
import Observation

/// What the library screens do with songs (Android's LibraryViewModel actions): play, queue,
/// favourite, Smart Radio. One-line results show as a toast ([message]).
@MainActor
@Observable
final class LibraryActions {
    /// The radio in the queue (for "New radio picks") and what it already suggested.
    struct RadioSession: Equatable {
        let seed: RadioSeed
        let startSongId: Int64
        let suggested: Set<Int64>
    }

    var message: String?
    private(set) var messageID = UUID()
    private(set) var radio: RadioSession?

    private let database: LibraryDatabase
    private let player: PlayerController
    private let mixes: MixStore

    init(database: LibraryDatabase, player: PlayerController, mixes: MixStore) {
        self.database = database
        self.player = player
        self.mixes = mixes
    }

    func show(_ text: String) {
        messageID = UUID()
        message = text
    }

    func fixTags(_ songs: [Song]) {
        let started = AppServices.shared.fixTags.fixInPlace(songs)
        show(started ? String(localized: "Fixing tags for these songs. You can keep browsing.") : String(localized: "A tag repair is already running, or no songs are available."))
    }

    func dismissMessage(id: UUID) {
        if messageID == id { message = nil }
    }

    /// [slots]: each song's playlist position, when [origin] is a playlist (a song may be in it twice).
    func play(_ songs: [Song], startIndex: Int, origin: CollectionRef? = nil, slots: [Int]? = nil, source: PlaybackSource? = nil) {
        if songs.isEmpty { return }
        player.playCollection(songs, startIndex: min(max(startIndex, 0), songs.count - 1), origin: origin, slots: slots, source: source)
    }

    func playInOrder(_ songs: [Song], origin: CollectionRef? = nil, slots: [Int]? = nil, source: PlaybackSource? = nil) {
        if songs.isEmpty { return }
        player.setShuffleModeEnabled(false)
        player.playCollection(songs, startIndex: 0, origin: origin, slots: slots, source: source)
    }

    /// Plays [songs] shuffled: the same shuffle mode the playlists use.
    func playShuffled(_ songs: [Song], origin: CollectionRef? = nil, slots: [Int]? = nil, source: PlaybackSource? = nil) {
        if songs.isEmpty { return }
        player.setShuffleModeEnabled(true)
        player.playCollection(songs, startIndex: Int.random(in: 0..<songs.count), origin: origin, slots: slots, source: source)
    }

    /// Plays the smart mix [key] in mix order, as its page's Play button does.
    func playMix(_ key: String) {
        guard let mix = mixes.mix(key) else { return }
        playInOrder(songs(mix.songIds), source: .smartPlaylist(key))
    }

    func playNext(_ song: Song, source: PlaybackSource? = nil) {
        player.playNext(song, source: source)
        show(String(localized: "\"\(song.title)\" will play next"))
    }

    func addToQueue(_ song: Song, source: PlaybackSource? = nil) {
        player.addToQueue(song, source: source)
        show(String(localized: "Added to queue"))
    }

    func toggleFavorite(_ song: Song) {
        do {
            try database.toggleFavorite(songId: song.id)
            // Read the database result rather than trusting a potentially older row snapshot.
            guard let updated = try database.song(id: song.id) else { return }
            show(updated.isFavorite ? String(localized: "Added to Liked Songs") : String(localized: "Removed from Liked Songs"))
        } catch { show(String(localized: "Couldn't change the favourite: \(error.localizedDescription)")) }
    }

    /// Deletes [song]'s file from the Erhu folder for good, after the user confirmed: first out of
    /// the queue (so playback moves on and never reaches it), then the file, then the library and
    /// playlists. A rescan rebuilds albums and artists without it.
    func deleteFromDevice(_ song: Song) {
        let url = song.url
        guard LibraryPaths.relativePath(of: url) != nil else {
            show(String(localized: "Couldn't delete “\(song.title)”: it isn't in the Erhu folder."))
            return
        }
        player.removeSong(song.id)
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            show(String(localized: "Couldn't delete “\(song.title)”: \(error.localizedDescription)"))
            return
        }
        do {
            try database.forgetSong(song.id)
        } catch {
            show(String(localized: "The file was deleted, but the library couldn't be updated: \(error.localizedDescription)"))
        }
        AppServices.shared.library.scan()
        show(String(localized: "Deleted “\(song.title)” from this device"))
    }

    /// The library songs with [ids], in that order (missing ones left out).
    func songs(_ ids: [Int64]) -> [Song] {
        let found = (try? database.songs(ids: ids)) ?? []
        let byId = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byId[$0] }
    }

    // MARK: Smart Radio

    /// Starts a new queue: the seed's start song, then the radio's picks, in radio order.
    func startRadio(_ seed: RadioSeed) {
        Task {
            guard let plan = await mixes.radio(seed) else { return report(nil) }
            playRadio(plan)
        }
    }

    /// Browsing is silent. Play, Shuffle and track selection retain the same station session.
    func playRadio(_ plan: RadioPlan, startingAt songId: Int64? = nil, shuffled: Bool = false) {
        let queue = songs([plan.startSongId] + plan.songIds)
        guard !queue.isEmpty else { return report(nil) }
        let index = songId.flatMap { id in queue.firstIndex { $0.id == id } } ?? (shuffled ? Int.random(in: 0..<queue.count) : 0)
        player.setShuffleModeEnabled(shuffled)
        player.playCollection(queue, startIndex: index, origin: nil)
        radio = RadioSession(seed: plan.seed, startSongId: queue[index].id, suggested: Set(queue.map(\.id)))
        // The station page already says what the radio is built from; playing it needs no toast.
    }

    /// A radio from the song playing now: it keeps playing and the radio replaces what comes next.
    func startRadioFromCurrent() {
        guard let current = player.state.currentSong else { return }
        replaceUpcomingWithRadio(.song(current.id), startSongId: current.id, exclude: [])
    }

    /// Fresh picks for the radio in the queue, avoiding the songs it already suggested.
    func refreshRadio() {
        guard let session = radio else { return }
        replaceUpcomingWithRadio(session.seed, startSongId: session.startSongId, exclude: session.suggested)
    }

    private func replaceUpcomingWithRadio(_ seed: RadioSeed, startSongId: Int64, exclude: Set<Int64>) {
        Task {
            guard let plan = await mixes.radio(seed, exclude: exclude, startSongId: startSongId) else { return report(nil) }
            let picks = songs(plan.songIds)
            if picks.isEmpty { return report(plan) }
            player.setShuffleModeEnabled(false)
            player.replaceUpcoming(picks)
            radio = RadioSession(seed: seed, startSongId: startSongId, suggested: exclude.union(plan.songIds))
            report(plan)
        }
    }

    private func report(_ plan: RadioPlan?) {
        guard let plan else { return show(String(localized: "No songs to start a radio from")) }
        if plan.songIds.isEmpty { return show(String(localized: "Not enough other songs for a radio from “\(plan.name)”")) }
        let basis = plan.basedOn.map(\.label)
        let reasons: String
        switch basis.count {
        case 0: reasons = ""
        default: reasons = " · " + String(localized: "by \(basis.formatted(.list(type: .and)))")
        }
        show(String(localized: "Radio from “\(plan.name)”: \(countLabel(plan.songIds.count, .song))") + reasons)
    }

    // MARK: Playlists

    func createPlaylist(_ name: String, songs: [Song] = []) {
        let trimmed = name.trimmed
        if trimmed.isEmpty { return }
        do {
            _ = try database.createPlaylist(name: trimmed, songIds: songs.map(\.id))
            show(songs.isEmpty ? "Created \"\(trimmed)\"" : String(localized: "Added to \"\(trimmed)\""))
        } catch {
            show(String(localized: "Couldn't create the playlist: \(error.localizedDescription)"))
        }
    }

    func add(_ songs: [Song], to playlist: Playlist) {
        do {
            var added = 0
            for song in songs where try database.appendSong(song.id, toPlaylist: playlist.id) { added += 1 }
            show(added == 0 ? String(localized: "Already in \"\(playlist.name)\"") : "Added \(countLabel(added, .song)) to \"\(playlist.name)\"")
        } catch {
            show(String(localized: "Couldn't add to the playlist: \(error.localizedDescription)"))
        }
    }
}

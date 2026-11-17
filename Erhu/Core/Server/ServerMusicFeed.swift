import Foundation

/// The connected server's songs that the library doesn't have, offered to Smart Playlists,
/// radio stations and VYBE alongside the library's own: their facts (genre, tempo, year,
/// length) and tags (the text VYBE matches). Empty while no server answers, so those features
/// then use the library alone. Set by [ServerStore]; read from any thread.
final class ServerMusicFeed: @unchecked Sendable {
    static let shared = ServerMusicFeed()
    /// Posted (on the main thread) when the songs offered change.
    static let didChange = Notification.Name("ServerMusicFeed.didChange")

    private let lock = NSLock()
    private var facts: [TrackFacts] = []
    private var tags: [SongTags] = []
    private var signature: [Int64] = []

    /// Turns song ids from a mix, a station or VYBE that belong to the server into playable
    /// songs (set by [ServerStore]; ids it doesn't know are left out).
    @MainActor static var resolve: (([Int64]) -> [Int64: Song])?

    func tracks() -> [TrackFacts] { lock.withLock { facts } }
    func songTags() -> [SongTags] { lock.withLock { tags } }

    /// Replaces the songs offered; posts [didChange] when they differ.
    func set(_ facts: [TrackFacts], _ tags: [SongTags]) {
        let ids = facts.map(\.songId)
        let changed = lock.withLock { () -> Bool in
            guard ids != signature || facts != self.facts else { return false }
            self.facts = facts
            self.tags = tags
            signature = ids
            return true
        }
        if changed {
            DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: nil) }
        }
    }

    /// The facts and tags of [songs] on server [accountId], under the ids streamed songs use.
    static func describe(_ songs: [ServerSong], accountId: UUID) -> ([TrackFacts], [SongTags]) {
        func negativeId(_ text: String) -> Int64 {
            -(Int64(ServerStreamPaths.hash(text) & 0x3fff_ffff_ffff_ffff) + 1)
        }
        var facts: [TrackFacts] = []
        var tags: [SongTags] = []
        facts.reserveCapacity(songs.count)
        tags.reserveCapacity(songs.count)
        for song in songs where song.isVideo != true {
            let id = ServerStreamPaths.songId(accountId: accountId, remoteId: song.id)
            let artist = song.artist ?? ""
            let album = song.album ?? ""
            let bpm = (song.bpm ?? 0) > 0 ? song.bpm : nil
            let year = (song.year ?? 0) > 0 ? song.year : nil
            facts.append(TrackFacts(songId: id, title: song.title,
                                    artistId: negativeId("artist:" + SearchNormalizer.normalize(artist)), artist: artist,
                                    albumId: negativeId("album:\(accountId.uuidString)/" + (song.albumId ?? album)), album: album,
                                    genre: song.genre, bpm: bpm, durationMs: Int64(song.duration ?? 0) * 1000,
                                    isFavorite: song.starred != nil, addedAt: 0, year: year))
            tags.append(SongTags(songId: id, title: song.title, artist: artist, album: album, genre: song.genre,
                                 year: year ?? 0, bpm: bpm, lyricsExcerpt: nil))
        }
        return (facts, tags)
    }
}

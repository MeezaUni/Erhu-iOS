import Foundation

enum LibrarySort: String, CaseIterable, Sendable {
    case title, titleDescending, recentlyAdded, recentlyPlayed, artist, album, newestYear, oldestYear, mostPlayed

    var label: String {
        switch self {
        case .title: "Title · A–Z"
        case .titleDescending: "Title · Z–A"
        case .recentlyAdded: "Recently added"
        case .recentlyPlayed: "Recently played"
        case .artist: "Artist · A–Z"
        case .album: "Album · A–Z"
        case .newestYear: "Year · newest first"
        case .oldestYear: "Year · oldest first"
        case .mostPlayed: "Most played"
        }
    }

    var shortLabel: String {
        switch self {
        case .title: "A–Z"
        case .titleDescending: "Z–A"
        case .recentlyAdded: "Added"
        case .recentlyPlayed: "Played"
        case .artist: "Artist"
        case .album: "Album"
        case .newestYear: "Newest"
        case .oldestYear: "Oldest"
        case .mostPlayed: "Most played"
        }
    }

    static let albums: [Self] = [.title, .titleDescending, .recentlyAdded, .recentlyPlayed, .artist, .newestYear, .oldestYear, .mostPlayed]
    static let songs: [Self] = [.title, .titleDescending, .recentlyAdded, .recentlyPlayed, .artist, .album, .mostPlayed]
}

enum LibraryMood: String, CaseIterable, Sendable {
    case all, chill, highEnergy, lateNight

    var label: String {
        switch self {
        case .all: "Mood"
        case .chill: "Chill"
        case .highEnergy: "High energy"
        case .lateNight: "Late night"
        }
    }

    func matches(_ song: Song) -> Bool {
        guard self != .all else { return true }
        let track = TrackFacts(songId: song.id, title: song.title, artistId: song.artistId, artist: song.artist,
                               albumId: song.albumId, album: song.album, genre: song.genre, bpm: song.bpm,
                               durationMs: song.durationMs, isFavorite: song.isFavorite, addedAt: song.dateModified)
        switch self {
        case .all: return true
        case .chill: return Moods.isChill(track)
        case .highEnergy: return Moods.isHighEnergy(track)
        case .lateNight: return Moods.isLateNight(track)
        }
    }
}

/// Snapshots keep filtering and sorting off the UI thread, and invalidate only when inputs change.
struct AlbumBrowseRequest: Hashable, Sendable {
    var albums: [Album]
    var songs: [Song]
    var facts: [Int64: LibraryBrowseFact]
    var lastPlayed: [Int64: Int64]
    var query: String
    var sort: LibrarySort

    func results() -> [Album] {
        var albumFacts: [Int64: LibraryBrowseFact] = [:]
        for song in songs {
            let fact = facts[song.id] ?? LibraryBrowseFact(addedAt: song.dateModified)
            var aggregate = albumFacts[song.albumId, default: LibraryBrowseFact()]
            aggregate.addedAt = max(aggregate.addedAt, fact.addedAt)
            aggregate.lastPlayedAt = max(aggregate.lastPlayedAt, fact.lastPlayedAt)
            aggregate.plays += fact.plays
            albumFacts[song.albumId] = aggregate
        }
        let search = SectionSearch(query)
        return albums.filter { search.matches([$0.title, $0.artist]) }.map { album in
            let fact = albumFacts[album.id, default: LibraryBrowseFact()]
            return BrowseEntry(value: album, id: album.id, title: album.title, artist: album.artist,
                               album: album.title, year: album.year, added: fact.addedAt,
                               played: max(fact.lastPlayedAt, lastPlayed[album.id, default: 0]), plays: fact.plays)
        }.sorted { BrowseEntry.precedes($0, $1, sort: sort) }.map(\.value)
    }
}

struct SongBrowseRequest: Hashable, Sendable {
    var songs: [Song]
    var facts: [Int64: LibraryBrowseFact]
    var query: String
    var sort: LibrarySort
    /// Empty means all genres; the sentinel represents songs with no usable genre tag.
    var genre = ""
    var mood = LibraryMood.all

    func results() -> [Song] {
        let search = SectionSearch(query)
        return songs.filter { song in
            let genres = Genres.parse(song.genre)
            let matchesGenre = genre.isEmpty || (genre == LibraryBrowse.untaggedGenre ? genres.isEmpty : genres.contains { SectionSearch.key($0) == genre })
            return matchesGenre && mood.matches(song) && search.matches([song.title, song.artist, song.album, song.genre ?? ""])
        }.map { song in
            let fact = facts[song.id] ?? LibraryBrowseFact(addedAt: song.dateModified)
            return BrowseEntry(value: song, id: song.id, title: song.title, artist: song.artist, album: song.album,
                               year: song.year, added: fact.addedAt, played: fact.lastPlayedAt, plays: fact.plays)
        }.sorted { BrowseEntry.precedes($0, $1, sort: sort) }.map(\.value)
    }
}

enum LibraryBrowse {
    static let untaggedGenre = "\u{0}"
    static func genres(in songs: [Song]) -> [String] {
        var values: [String: String] = [:]
        for song in songs {
            for genre in Genres.parse(song.genre) {
                let key = SectionSearch.key(genre)
                if values[key] == nil { values[key] = genre }
            }
        }
        return values.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// Keep every script, including combining marks. ASCII-only normalization loses Hindi/Arabic titles.
struct SectionSearch {
    private let tokens: [String]
    init(_ query: String) { tokens = Self.key(query).split(whereSeparator: \.isWhitespace).map(String.init) }

    static func key(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased().replacingOccurrences(of: "$", with: "s")
    }

    func matches(_ fields: [String]) -> Bool {
        guard !tokens.isEmpty else { return true }
        let haystack = fields.map(Self.key).joined(separator: "\n")
        return SearchNormalizer.matches(haystack, tokens.joined(separator: " "))
    }
}

private struct BrowseEntry<Value> {
    let value: Value
    let id: Int64
    let title: String
    let artist: String
    let album: String
    let year: Int
    let added: Int64
    let played: Int64
    let plays: Int

    init(value: Value, id: Int64, title: String, artist: String, album: String, year: Int, added: Int64, played: Int64, plays: Int) {
        self.value = value; self.id = id
        self.title = SectionSearch.key(title); self.artist = SectionSearch.key(artist); self.album = SectionSearch.key(album)
        self.year = year; self.added = added; self.played = played; self.plays = plays
    }

    static func precedes(_ a: Self, _ b: Self, sort: LibrarySort) -> Bool {
        switch sort {
        case .recentlyAdded: if a.added != b.added { return a.added > b.added }
        case .recentlyPlayed: if a.played != b.played { return a.played > b.played }
        case .mostPlayed: if a.plays != b.plays { return a.plays > b.plays }
        case .newestYear, .oldestYear:
            if (a.year > 0) != (b.year > 0) { return a.year > 0 }
            if a.year != b.year { return sort == .newestYear ? a.year > b.year : a.year < b.year }
        case .artist: if a.artist != b.artist { return compare(a.artist, b.artist) }
        case .album:
            if a.album != b.album { return compare(a.album, b.album) }
            if a.artist != b.artist { return compare(a.artist, b.artist) }
        case .titleDescending: if a.title != b.title { return compare(b.title, a.title) }
        case .title: break
        }
        if a.title != b.title { return compare(a.title, b.title) }
        if a.artist != b.artist { return compare(a.artist, b.artist) }
        return a.id < b.id
    }

    private static func compare(_ a: String, _ b: String) -> Bool {
        // Numeric order places "2" before "10". A literal tie-break keeps ordering strict.
        let result = a.compare(b, options: .numeric)
        return result == .orderedSame ? a < b : result == .orderedAscending
    }
}

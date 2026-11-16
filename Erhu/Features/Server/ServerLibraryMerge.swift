import Foundation

/// An album in the Albums grid: one of the library's, or one on a connected server.
enum AlbumGridItem: Identifiable, Hashable, Sendable {
    case local(Album)
    case server(accountId: UUID, album: ServerCatalog.Album)

    var id: String {
        switch self {
        case .local(let album): "local:\(album.id)"
        case .server(let account, let album): "server:\(account.uuidString)/\(album.id)"
        }
    }

    var title: String {
        switch self {
        case .local(let album): album.title
        case .server(_, let album): album.name
        }
    }

    var artist: String {
        switch self {
        case .local(let album): album.artist
        case .server(_, let album): album.artist ?? ""
        }
    }

    var year: Int {
        switch self {
        case .local(let album): album.year
        case .server(_, let album): album.year ?? 0
        }
    }
}

/// Which music the Albums and Songs pages show (their Source filter).
enum LibrarySource: String, CaseIterable, Sendable {
    case all, local, streamed

    var label: String {
        switch self {
        case .all: String(localized: "All music")
        case .local: String(localized: "On this device")
        case .streamed: String(localized: "Streamed")
        }
    }
}

/// Puts a server's music into the library's own pages: an album the library has gets the
/// server's other songs (marked as streamed); albums and songs only on the server join in
/// order; nothing shows twice.
enum ServerLibraryMerge {
    // MARK: Matching

    private static func norm(_ text: String) -> String { SearchNormalizer.normalize(text) }

    /// The same artist, allowing "Coldplay" against "Coldplay, Guest".
    static func sameArtist(_ a: String, _ b: String) -> Bool {
        let x = norm(a), y = norm(b)
        return x.isEmpty || y.isEmpty || x == y || x.contains(y) || y.contains(x)
    }

    static func sameAlbum(_ local: Album, _ server: ServerCatalog.Album) -> Bool {
        norm(local.title) == norm(server.name) && sameArtist(local.artist, server.artist ?? "")
    }

    /// Titles and artists of songs, to leave out server songs the library already has.
    struct SongKeys: Sendable {
        private var artistsByTitle: [String: [String]] = [:]
        init(_ songs: [Song]) {
            for song in songs { artistsByTitle[ServerLibraryMerge.norm(song.title), default: []].append(song.artist) }
        }
        func contains(title: String, artist: String) -> Bool {
            artistsByTitle[ServerLibraryMerge.norm(title)]?.contains { ServerLibraryMerge.sameArtist($0, artist) } ?? false
        }
    }

    // MARK: Albums

    /// The library's albums (already searched and sorted) with the server's that the library
    /// doesn't have, in the same order where the sort applies to both (title, artist, album,
    /// year); otherwise the server's follow. While searching, each side keeps its own best-first
    /// order, the library's first.
    static func albums(local: [Album], server: [ServerCatalog.Album], accountId: UUID?, sort: LibrarySort,
                       searching: Bool, source: LibrarySource = .all, allLocal: [Album]? = nil) -> [AlbumGridItem] {
        let mine = source == .streamed ? [] : local.map(AlbumGridItem.local)
        guard let accountId, !server.isEmpty, source != .local else { return mine }
        // Albums the library has are shown once, as the library's (with the server's songs inside).
        var localByTitle: [String: [Album]] = [:]
        for album in allLocal ?? local { localByTitle[norm(album.title), default: []].append(album) }
        var theirs = server.filter { album in !(localByTitle[norm(album.name)]?.contains { sameAlbum($0, album) } ?? false) }
            .map { AlbumGridItem.server(accountId: accountId, album: $0) }
        guard !searching, let before = order(sort) else { return mine + theirs }
        theirs.sort(by: before)
        return merge(mine, theirs, by: before)
    }

    private static func merge<T>(_ mine: [T], _ theirs: [T], by before: (T, T) -> Bool) -> [T] {
        var merged: [T] = []
        merged.reserveCapacity(mine.count + theirs.count)
        var i = 0, j = 0
        while i < mine.count, j < theirs.count {
            if before(theirs[j], mine[i]) { merged.append(theirs[j]); j += 1 } else { merged.append(mine[i]); i += 1 }
        }
        merged += mine[i...]
        merged += theirs[j...]
        return merged
    }

    private static func less(_ a: String, _ b: String) -> Bool { a.localizedStandardCompare(b) == .orderedAscending }

    private static func order(_ sort: LibrarySort) -> ((AlbumGridItem, AlbumGridItem) -> Bool)? {
        switch sort {
        case .title, .album: return { less($0.title, $1.title) }
        case .titleDescending: return { less($1.title, $0.title) }
        case .artist: return { $0.artist == $1.artist ? less($0.title, $1.title) : less($0.artist, $1.artist) }
        case .newestYear: return { $0.year > $1.year }
        case .oldestYear: return { $0.year < $1.year }
        default: return nil
        }
    }

    /// The server's songs of [album] that the library's copy lacks ([localSongs]).
    static func extraSongs(for album: Album, localSongs: [Song], in index: ServerCatalogIndex) -> [ServerSong] {
        guard let match = index.catalog.albums.first(where: { sameAlbum(album, $0) }),
              let serverAlbum = index.album(match.id) else { return [] }
        let have = SongKeys(localSongs)
        return serverAlbum.song.filter { $0.isVideo != true && !have.contains(title: $0.title, artist: $0.artist ?? album.artist) }
    }

    /// An album's songs with the server's extras, in disc and track order (unknown positions last).
    static func albumTracks(_ local: [Song], _ extras: [Song]) -> [Song] {
        guard !extras.isEmpty else { return local }
        func position(_ song: Song) -> (Int, Int) {
            (song.discNumber > 0 ? song.discNumber : 1, song.trackNumber > 0 ? song.trackNumber : Int.max)
        }
        return (local + extras).enumerated().sorted { a, b in
            let pa = position(a.element), pb = position(b.element)
            return pa != pb ? pa < pb : a.offset < b.offset
        }.map(\.element)
    }

    // MARK: Songs

    /// A server's songs for the Songs page that the library doesn't have: matching [query] best
    /// first, or all by title; the genre filter applies when set (moods need the library's tags).
    static func songs(in index: ServerCatalogIndex, query: String, genre: String, excluding library: SongKeys,
                      limit: Int = 5000) -> [ServerSong] {
        let text = query.trimmingCharacters(in: .whitespaces)
        var songs = text.isEmpty
            ? index.catalog.songs.sorted { less($0.title, $1.title) }
            : index.search(text, limit: 500).songs
        songs = songs.filter { !library.contains(title: $0.title, artist: $0.artist ?? "") }
        if !genre.isEmpty {
            songs = songs.filter { song in
                let genres = Genres.parse(song.genre)
                return genre == LibraryBrowse.untaggedGenre ? genres.isEmpty : genres.contains { SectionSearch.key($0) == genre }
            }
        }
        return Array(songs.prefix(limit))
    }

    /// The library's songs (already searched and sorted) and streamed ones in one list: in order
    /// for title, artist, album and year sorts; otherwise (and while searching) streamed ones follow.
    static func songList(local: [Song], streamed: [Song], sort: LibrarySort, searching: Bool, source: LibrarySource) -> [Song] {
        switch source {
        case .local: return local
        case .streamed: return streamed
        case .all: break
        }
        guard !streamed.isEmpty else { return local }
        let before: ((Song, Song) -> Bool)?
        switch sort {
        case .title: before = { less($0.title, $1.title) }
        case .titleDescending: before = { less($1.title, $0.title) }
        case .artist: before = { $0.artist == $1.artist ? less($0.title, $1.title) : less($0.artist, $1.artist) }
        case .album: before = { $0.album == $1.album ? less($0.title, $1.title) : less($0.album, $1.album) }
        case .newestYear: before = { $0.year > $1.year }
        case .oldestYear: before = { $0.year < $1.year }
        default: before = nil
        }
        guard !searching, let before else { return local + streamed }
        return merge(local, streamed.sorted(by: before), by: before)
    }
}

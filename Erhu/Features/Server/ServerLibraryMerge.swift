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

enum ServerLibraryMerge {
    /// The library's albums (already searched and sorted) with a server's, in the same order where
    /// the sort applies to both (title, artist, album, year); otherwise the server's follow.
    /// While searching, each side keeps its own best-first order, the library's first.
    static func albums(local: [Album], server: [ServerCatalog.Album], accountId: UUID?, sort: LibrarySort,
                       searching: Bool) -> [AlbumGridItem] {
        let mine = local.map(AlbumGridItem.local)
        guard let accountId, !server.isEmpty else { return mine }
        var theirs = server.map { AlbumGridItem.server(accountId: accountId, album: $0) }
        guard !searching, let before = order(sort) else { return mine + theirs }
        theirs.sort(by: before)
        // Both sides are in order: merge them, keeping the library's own order intact.
        var merged: [AlbumGridItem] = []
        merged.reserveCapacity(mine.count + theirs.count)
        var i = 0, j = 0
        while i < mine.count, j < theirs.count {
            if before(theirs[j], mine[i]) { merged.append(theirs[j]); j += 1 } else { merged.append(mine[i]); i += 1 }
        }
        merged += mine[i...]
        merged += theirs[j...]
        return merged
    }

    private static func order(_ sort: LibrarySort) -> ((AlbumGridItem, AlbumGridItem) -> Bool)? {
        func less(_ a: String, _ b: String) -> Bool { a.localizedStandardCompare(b) == .orderedAscending }
        switch sort {
        case .title, .album: return { less($0.title, $1.title) }
        case .titleDescending: return { less($1.title, $0.title) }
        case .artist: return { $0.artist == $1.artist ? less($0.title, $1.title) : less($0.artist, $1.artist) }
        case .newestYear: return { $0.year > $1.year }
        case .oldestYear: return { $0.year < $1.year }
        default: return nil
        }
    }

    /// A server's songs for the Songs page: matching [query] best first, or all by title; the
    /// genre filter applies when set (moods need tags only the library has).
    static func songs(in index: ServerCatalogIndex, query: String, genre: String, limit: Int = 500) -> [ServerSong] {
        let text = query.trimmingCharacters(in: .whitespaces)
        var songs = text.isEmpty
            ? index.catalog.songs.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            : index.search(text, limit: limit).songs
        if !genre.isEmpty {
            songs = songs.filter { song in
                let genres = Genres.parse(song.genre)
                return genre == LibraryBrowse.untaggedGenre ? genres.isEmpty : genres.contains { SectionSearch.key($0) == genre }
            }
        }
        return Array(songs.prefix(limit))
    }
}

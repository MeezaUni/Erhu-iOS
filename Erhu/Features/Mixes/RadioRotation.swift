import Foundation

/// When Home's radio stations and banners change (Android's RadioRotation). Each stays for a
/// fixed window of the clock (the same on every visit within it), then the next window brings a
/// different set, so Home doesn't show the same stations for days.
enum RadioRotation {
    static let radioHours = 5
    static let bannerHours = 8
    /// Home shows this many stations at a time; a station page recommends [recommended] more.
    static let homeRadios = 5
    static let recommended = 5
    /// Stations rotate through the listener's top artists (by plays), then the rest of the library.
    private static let poolSize = 15

    /// The window of [hours] that [date] falls in.
    static func slot(_ date: Date = Date(), hours: Int) -> Int64 {
        Int64(floor(date.timeIntervalSince1970 / Double(hours * 3600)))
    }

    /// When the window of [hours] containing [date] ends.
    static func nextChange(after date: Date = Date(), hours: Int) -> Date {
        Date(timeIntervalSince1970: Double(slot(date, hours: hours) + 1) * Double(hours * 3600))
    }

    /// One album per artist that can lead a radio: the artists played most first (each by its most
    /// played album), then everyone else by album size. Compilations and unknown artists can't
    /// represent a station.
    static func pool(albums: [Album], tracks: [TrackFacts], plays: [MonthlyPlays]) -> [Album] {
        let usable = albums.filter { $0.songCount > 0 && !$0.isCompilation && $0.artistId > 0 && hasArtist($0) }
        let albumOfSong = Dictionary(tracks.map { ($0.songId, $0.albumId) }, uniquingKeysWith: { first, _ in first })
        var playsByAlbum: [Int64: Int] = [:]
        for play in plays { if let album = albumOfSong[play.songId] { playsByAlbum[album, default: 0] += play.plays } }
        let leaders = Dictionary(grouping: usable, by: \.artistId).values.compactMap { own -> (album: Album, plays: Int)? in
            guard let best = own.max(by: { a, b in
                let pa = playsByAlbum[a.id, default: 0], pb = playsByAlbum[b.id, default: 0]
                if pa != pb { return pa < pb }
                if a.songCount != b.songCount { return a.songCount < b.songCount }
                return a.id > b.id
            }) else { return nil }
            return (best, own.reduce(0) { $0 + playsByAlbum[$1.id, default: 0] })
        }
        return leaders.sorted { a, b in
            if a.plays != b.plays { return a.plays > b.plays }
            if a.album.songCount != b.album.songCount { return a.album.songCount > b.album.songCount }
            return a.album.id < b.album.id
        }.map(\.album)
    }

    /// The stations of window [slot]: a different draw from the top of the pool each window.
    static func stations(_ pool: [Album], slot: Int64, count: Int = homeRadios) -> [Album] {
        Array(pool.prefix(poolSize).sorted { rank($0, slot) < rank($1, slot) }.prefix(count))
    }

    /// Stations to try next from the one on screen: first the other artists playing on it (in the
    /// order they appear), then the current window's rotation; never the station's own artist.
    static func recommendations(_ pool: [Album], current: Album, stationArtistIds: [Int64], slot: Int64) -> [Album] {
        let byArtist = Dictionary(pool.map { ($0.artistId, $0) }, uniquingKeysWith: { first, _ in first })
        let related = stationArtistIds.compactMap { byArtist[$0] }
        var seenArtists = Set<Int64>()
        return (related + stations(pool, slot: slot, count: pool.count))
            .filter { $0.artistId != current.artistId && $0.id != current.id && seenArtists.insert($0.artistId).inserted }
            .prefix(recommended)
            .map { $0 }
    }

    private static func rank(_ album: Album, _ slot: Int64) -> (Int64, Int64) {
        (FeaturedAlbums.dailyRank(album.artistId, slot), album.id)
    }

    private static func hasArtist(_ album: Album) -> Bool {
        let name = album.artist.trimmingCharacters(in: .whitespaces)
        return !name.isEmpty && name.caseInsensitiveCompare("Unknown Artist") != .orderedSame && name != "<unknown>"
    }
}

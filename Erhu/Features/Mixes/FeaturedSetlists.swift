import Foundation

enum FeaturedSetlist: Identifiable {
    case album(Album)
    case radio(seed: RadioSeed, title: String, subtitle: String, cover: Song)
    var id: String {
        switch self {
        case .album(let album): "album:\(album.id)"
        case .radio(let seed, _, _, _): "radio:" + seed.key
        }
    }
    var albumID: Int64 {
        switch self {
        case .album(let album): album.id
        case .radio(_, _, _, let cover): cover.albumId
        }
    }
}

enum FeaturedSetlists {
    /// A release gets one place: either its album or its station. Extra song stations come
    /// from other releases, so an album never has a duplicate radio card alongside it.
    static func select(albums: [Album], covers: [Int64: Song], radioSongs: [Song], includesRadio: Bool) -> [FeaturedSetlist] {
        var usedAlbums = Set<Int64>()
        var result: [FeaturedSetlist] = []
        for album in albums where usedAlbums.insert(album.id).inserted {
            if includesRadio, result.count % 3 == 1, let cover = covers[album.id] {
                result.append(.radio(seed: .album(album.id), title: album.title, subtitle: "Album radio", cover: cover))
            } else { result.append(.album(album)) }
        }
        guard includesRadio else { return result }
        var extras: [FeaturedSetlist] = []
        for song in radioSongs where extras.count < 3 {
            guard song.albumId > 0, usedAlbums.insert(song.albumId).inserted else { continue }
            extras.append(.radio(seed: .song(song.id), title: song.title, subtitle: song.artist + " · Song radio", cover: song))
        }
        // Distribute additional stations through the shelf rather than appending paired copies.
        for (index, station) in extras.enumerated() {
            result.insert(station, at: min(1 + index * 3, result.count))
        }
        return result
    }
}

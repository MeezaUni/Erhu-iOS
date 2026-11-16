import SwiftUI
import Observation

/// The primary destinations, switched by the bottom bar (Search is the separate button beside it).
enum LibrarySection: String, CaseIterable, Identifiable {
    case home, albums, library, vybe
    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: String(localized: "Home")
        case .albums: String(localized: "Albums")
        case .library: String(localized: "Library")
        case .vybe: String(localized: "VYBE")
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .albums: "square.stack"
        case .library: "music.note.house"
        case .vybe: "recordingtape"
        }
    }

    var selectedIcon: String {
        switch self {
        case .home: "house.fill"
        case .albums: "square.stack.fill"
        case .library: "music.note.house.fill"
        case .vybe: "recordingtape"
        }
    }
}

/// The full shelves the Library overview opens with "More".
enum LibraryShelf: String, Hashable {
    case playlists, favorites, artists

    var label: String {
        switch self {
        case .playlists: String(localized: "Playlists")
        case .favorites: String(localized: "Favorites")
        case .artists: String(localized: "Artists")
        }
    }
}

/// The tools in the side menu (Android's navigation drawer).
enum Tool: String, CaseIterable, Identifiable, Hashable {
    case soundCapsule, equalizer, autoFixTags, libraryBuilder, artworkFetcher, wifiTransfer, musicServer, settings
    var id: String { rawValue }

    var label: String {
        switch self {
        case .soundCapsule: String(localized: "Sound Capsule")
        case .equalizer: String(localized: "Equalizer")
        case .autoFixTags: String(localized: "Auto Fix Tags")
        case .libraryBuilder: String(localized: "Library Builder")
        case .artworkFetcher: String(localized: "Artwork Fetcher")
        case .wifiTransfer: String(localized: "Wi-Fi Transfer")
        case .musicServer: String(localized: "Music Server")
        case .settings: String(localized: "Settings")
        }
    }

    var icon: String {
        switch self {
        case .soundCapsule: "chart.bar.xaxis"
        case .equalizer: "slider.vertical.3"
        case .autoFixTags: "wand.and.stars"
        case .libraryBuilder: "folder"
        case .artworkFetcher: "photo.on.rectangle.angled"
        case .wifiTransfer: "wifi"
        case .musicServer: "server.rack"
        case .settings: "gearshape"
        }
    }
}

/// A page pushed inside a section.
enum Route: Hashable {
    case album(Int64)
    case artist(Int64)
    case playlist(Int64)
    case smartPlaylist(String)
    case radio(RadioSeed)
    case shelf(LibraryShelf)
    case allSongs
    case tool(Tool)
    case settingsPage(SettingsPageRoute)
    case transitionStudio(CollectionRef)
    case serverAlbum(ServerRef)
    case serverArtist(ServerRef)
    /// A server artist by name (id: the normalized name), with every credit naming them.
    case serverArtistNamed(ServerRef)
    case serverPlaylist(ServerRef)
    case serverAlbums(UUID)
}

/// Where the app is: the section, each section's own back stack, and what is presented on top.
@MainActor
@Observable
final class AppRouter {
    var section: LibrarySection = .home
    var vybeEnabled = true
    var paths: [LibrarySection: NavigationPath] = Dictionary(uniqueKeysWithValues: LibrarySection.allCases.map { ($0, NavigationPath()) })
    var scrollToTopRequests: [LibrarySection: Int] = [:]
    var showsSearch = false
    var showsDrawer = false
    var showsNowPlaying = false
    var songsForPlaylist: [Song]?
    var songForDetails: Song?
    /// The song whose tags are being edited by hand.
    var songForTagEdit: Song?
    /// The song waiting for "Delete from device" to be confirmed.
    var songForDeletion: Song?
    var showsNewPlaylist = false

    func open(_ route: Route) {
        paths[section, default: NavigationPath()].append(route)
    }

    func open(_ tool: Tool) {
        showsDrawer = false
        open(.tool(tool))
    }

    /// A tab always opens its root. Reselecting it also scrolls that root back to the top.
    func select(_ target: LibrarySection) {
        let reselecting = target == section
        paths[target] = NavigationPath()
        section = target
        showsDrawer = false
        if reselecting { scrollToTopRequests[target, default: 0] += 1 }
    }

    func binding(for section: LibrarySection) -> Binding<NavigationPath> {
        Binding(get: { self.paths[section] ?? NavigationPath() }, set: { self.paths[section] = $0 })
    }

    func reveal(_ source: PlaybackSource) {
        let destination: Route?
        switch source {
        case .album(let id): section = .albums; destination = .album(id)
        case .playlist(let id): section = .library; destination = .playlist(id)
        case .artist(let id): section = .library; destination = .artist(id)
        case .smartPlaylist(let key): section = .home; destination = .smartPlaylist(key)
        case .library: section = .library; destination = .allSongs
        case .favorites: section = .library; destination = .shelf(.favorites)
        case .vybe: section = vybeEnabled ? .vybe : .home; destination = nil
        case .server(let account, let album, let title):
            // A server album opens as a page; other server lists have no page of their own.
            guard let album else { return }
            section = .home
            destination = .serverAlbum(ServerRef(accountId: account, id: album, title: title))
        }
        paths[section] = destination.map { NavigationPath([$0]) } ?? NavigationPath()
        showsDrawer = false
        showsSearch = false
        showsNowPlaying = false
    }

    /// Opens the album of [song] (the library's, or its server's for a streamed song) and closes
    /// Now Playing.
    func showAlbum(of song: Song) {
        // A streamed song of an album in the library opens the library's album (which lists it).
        if song.isStream, song.albumId <= 0 {
            guard let found = ServerStream.shared.remote(for: song), let id = found.song.albumId else { return }
            go(.serverAlbum(ServerRef(accountId: found.accountId, id: id, title: found.song.album ?? song.album)), in: .home)
        } else if song.albumId > 0 {
            go(.album(song.albumId), in: .albums)
        }
    }

    /// Opens the artist of [song] and closes Now Playing.
    func showArtist(of song: Song) {
        if song.isStream {
            guard let found = ServerStream.shared.remote(for: song), let id = found.song.artistId else { return }
            go(.serverArtist(ServerRef(accountId: found.accountId, id: id, title: found.song.artist ?? song.artist)), in: .home)
        } else if song.artistId > 0 {
            go(.artist(song.artistId), in: .library)
        }
    }

    /// Opens an artist's page and closes Now Playing.
    func showArtist(_ route: Route) {
        if case .artist = route { go(route, in: .library) } else { go(route, in: .home) }
    }

    private func go(_ route: Route, in target: LibrarySection) {
        section = target
        paths[target] = NavigationPath([route])
        showsDrawer = false
        showsSearch = false
        showsNowPlaying = false
    }

    func songActions(_ actions: LibraryActions, hideFromMixes: ((Song) -> Void)? = nil, source: PlaybackSource? = nil) -> SongActions {
        SongActions(
            toggleFavorite: { actions.toggleFavorite($0) },
            playNext: { actions.playNext($0, source: source) },
            addToQueue: { actions.addToQueue($0, source: source) },
            startRadio: { [weak self] song in
                guard let self, self.vybeEnabled else { return }
                self.open(.radio(.song(song.id)))
            },
            addToPlaylist: { [weak self] song in self?.songsForPlaylist = [song] },
            viewDetails: { [weak self] song in self?.songForDetails = song },
            editTags: { [weak self] song in self?.songForTagEdit = song },
            fixTags: { song in actions.fixTags([song]) },
            hideFromMixes: hideFromMixes,
            deleteFromDevice: { [weak self] song in self?.songForDeletion = song }
        )
    }
}

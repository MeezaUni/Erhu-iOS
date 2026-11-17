import Foundation

/// Whether a song is a favourite right now. Lists, menus and Now Playing hold copies of songs
/// taken when they were listed or queued, so a heart reading the copy would keep showing what
/// it was before a tap; [Song.isFavoriteNow] asks the library (or the song's server) instead.
@MainActor
enum FavoriteStatus {
    /// A library song: set by [LibraryStore].
    static var library: ((Song) -> Bool?)?
    /// A streamed song: set by the music server store; nil while unknown (the copy's own value
    /// is used then).
    static var stream: ((Song) -> Bool?)?
}

extension Song {
    /// The favourite as it is now (a liked song shows a filled heart, an unliked one an outline).
    @MainActor var isFavoriteNow: Bool { (isStream ? FavoriteStatus.stream : FavoriteStatus.library)?(self) ?? isFavorite }
}

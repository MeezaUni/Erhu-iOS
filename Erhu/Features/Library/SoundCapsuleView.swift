import SwiftUI

/// Sound Capsule (Android's redesigned screen): a month of listening. The month and year with
/// previous / next, then minutes listened, plays and tracks in three columns, the top artists as
/// ranked rows, and the top songs and albums as shelves. The share button makes a stats card.
struct SoundCapsuleView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(LibraryActions.self) private var actions
    @Environment(AppRouter.self) private var router
    @Environment(\.palette) private var palette
    @State private var month = ListeningMonth.current
    @State private var months: [String] = []
    @State private var capsule: SoundCapsule?
    @State private var sharing = false

    private static let top = 5

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.xl) {
                monthHeader
                if let capsule {
                    if capsule.isEmpty {
                        emptyMonth
                    } else {
                        summary(capsule)
                        if !capsule.topArtists.isEmpty { topArtists(capsule.topArtists) }
                        if !capsule.topSongs.isEmpty { topSongs(capsule.topSongs) }
                        if !capsule.topAlbums.isEmpty { topAlbums(capsule.topAlbums) }
                    }
                }
            }
            .padding(.top, Spacing.sm)
            .padding(.bottom, Spacing.xl)
        }
        .navigationTitle("Sound Capsule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { sharing = true } label: { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Share stats")
            }
        }
        .sheet(isPresented: $sharing) { StatsShareSheet() }
        .task(id: "\(month)|\(library.songs.count)|\(library.recentAlbums.map(\.id))") { load() }
    }

    private func load() {
        months = (try? library.database.listeningMonths()) ?? []
        capsule = try? library.database.capsule(month: month)
    }

    /// Month and year on the left, previous / next on the right.
    private var monthHeader: some View {
        let all = Array(Set(months + [ListeningMonth.current])).sorted()
        let previous = all.last { $0 < month }
        let next = all.first { $0 > month }
        return HStack(spacing: 0) {
            Text(ListeningMonth.title(month)).font(.title2.weight(.bold)).lineLimit(1)
            Spacer(minLength: Spacing.sm)
            Button { if let previous { month = previous } } label: {
                Image(systemName: "chevron.backward").font(.body.weight(.semibold)).frame(width: 44, height: 44)
            }
            .disabled(previous == nil)
            .accessibilityLabel("Previous month")
            Button { if let next { month = next } } label: {
                Image(systemName: "chevron.forward").font(.body.weight(.semibold)).frame(width: 44, height: 44)
            }
            .disabled(next == nil)
            .accessibilityLabel("Next month")
        }
        .padding(.leading, Spacing.gutter)
        .padding(.trailing, Spacing.xs)
    }

    /// Minutes listened, plays and tracks: three equal columns straight on the page.
    private func summary(_ capsule: SoundCapsule) -> some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            figure(StatsText.number(capsule.listenedMs / 60_000), String(localized: "Minutes listened"))
            figure(StatsText.number(Int64(capsule.totalPlays)), StatsText.playsUnit(capsule.totalPlays))
            figure(StatsText.number(Int64(capsule.uniqueTracks)), StatsText.tracksUnit(capsule.uniqueTracks))
        }
        .padding(.horizontal, Spacing.gutter)
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title.weight(.bold)).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.subheadline).foregroundStyle(palette.onSurfaceVariant).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func heading(_ text: String) -> some View {
        Text(text.uppercased(with: .current)).font(.footnote.weight(.bold)).tracking(0.8)
            .foregroundStyle(palette.onSurface)
            .padding(.horizontal, Spacing.gutter)
    }

    /// Top artists as library rows: rank, round photo, name over play count.
    private func topArtists(_ artists: [RankedArtist]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            heading(String(localized: "Top artists")).padding(.bottom, Spacing.xs)
            ForEach(Array(artists.prefix(Self.top).enumerated()), id: \.element.artist.id) { index, ranked in
                Button { router.open(.artist(ranked.artist.id)) } label: {
                    HStack(spacing: 0) {
                        Text(StatsText.number(Int64(index + 1))).font(.body.weight(.bold))
                            .foregroundStyle(palette.onSurfaceVariant).frame(width: 24)
                        ArtistArtworkView(artist: ranked.artist, fontSize: 18, maxPixels: 144)
                            .frame(width: ArtworkSize.list, height: ArtworkSize.list)
                            .clipShape(Circle())
                            .padding(.leading, Spacing.sm)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ranked.artist.name).font(.body).lineLimit(1)
                            Text(StatsText.plays(ranked.plays)).font(.subheadline).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
                        }
                        .padding(.leading, Spacing.md)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Spacing.gutter)
                    .padding(.vertical, Spacing.sm)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func topSongs(_ songs: [RankedSong]) -> some View {
        let shown = Array(songs.prefix(Self.top))
        return shelf(String(localized: "Top songs")) {
            ForEach(Array(shown.enumerated()), id: \.element.song.id) { index, ranked in
                Button { actions.play(shown.map(\.song), startIndex: index) } label: {
                    tile(rank: index + 1, title: ranked.song.title, subtitle: ranked.song.artist, plays: ranked.plays) {
                        SongArtworkView(song: ranked.song, maxPixels: 432)
                    }
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityHint("Plays the month's top songs")
            }
        }
    }

    private func topAlbums(_ albums: [RankedAlbum]) -> some View {
        shelf(String(localized: "Top albums")) {
            ForEach(Array(albums.prefix(Self.top).enumerated()), id: \.element.album.id) { index, ranked in
                Button { router.open(.album(ranked.album.id)) } label: {
                    tile(rank: index + 1, title: ranked.album.title, subtitle: ranked.album.artist, plays: ranked.plays) {
                        AlbumArtworkView(albumId: ranked.album.id, maxPixels: 432)
                    }
                }
                .buttonStyle(PressScaleStyle())
            }
        }
    }

    /// A headed horizontal shelf; the gutter is content padding, so cards scroll to the edge.
    private func shelf<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            heading(title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Spacing.md) { content() }
                    .padding(.horizontal, Spacing.gutter)
            }
        }
    }

    /// A shelf card: square artwork with its rank, then title, subtitle and play count. Only the
    /// artwork is rounded, as in the album grid.
    private func tile<Artwork: View>(rank: Int, title: String, subtitle: String, plays: Int,
                                     @ViewBuilder artwork: () -> Artwork) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            artwork()
                .frame(width: ArtworkSize.shelf, height: ArtworkSize.shelf)
                .clipShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
                .overlay(alignment: .topLeading) {
                    Text(StatsText.number(Int64(rank))).font(.caption.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(.black.opacity(0.7)))
                        .padding(Spacing.sm)
                }
                .padding(.bottom, Spacing.xs)
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(subtitle).font(.caption).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
            Text(StatsText.plays(plays)).font(.caption2).foregroundStyle(palette.onSurfaceVariant).lineLimit(1)
        }
        .frame(width: ArtworkSize.shelf, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var emptyMonth: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "chart.bar.xaxis").font(.system(size: 48)).foregroundStyle(palette.onSurfaceVariant.opacity(0.5))
            Text("Nothing played in \(ListeningMonth.name(month)) yet").font(.headline).multilineTextAlignment(.center)
            Text("Songs you play this month show up here: your top songs, albums and artists.")
                .font(.subheadline).foregroundStyle(palette.onSurfaceVariant).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.xxl)
    }
}

/// Counts in the app's language, shared by the Sound Capsule and its stats cards.
enum StatsText {
    static func number(_ value: Int64) -> String { value.formatted(.number) }

    /// "1 play" / "12 plays".
    static func plays(_ plays: Int) -> String {
        plays == 1 ? String(localized: "1 play") : String(localized: "\(plays.formatted(.number)) plays")
    }

    /// "Play" / "Plays" as the label under a count.
    static func playsUnit(_ count: Int) -> String {
        count == 1 ? String(localized: "stats.unit.play", defaultValue: "Play") : String(localized: "stats.unit.plays", defaultValue: "Plays")
    }

    /// "Track" / "Tracks" as the label under a count.
    static func tracksUnit(_ count: Int) -> String {
        count == 1 ? String(localized: "stats.unit.track", defaultValue: "Track") : String(localized: "stats.unit.tracks", defaultValue: "Tracks")
    }
}

/// Listening months as stored ("YYYY-MM", local calendar).
enum ListeningMonth {
    static var current: String { LibraryDatabase.keys(Date(), calendar: .current).month }

    private static func date(_ month: String) -> Date? {
        let parts = month.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let number = Int(parts[1]) else { return nil }
        return Calendar.current.date(from: DateComponents(year: year, month: number, day: 1))
    }

    /// "October 2026".
    static func title(_ month: String) -> String {
        guard let date = date(month) else { return month }
        return date.formatted(.dateTime.month(.wide).year())
    }

    /// "October".
    static func name(_ month: String) -> String {
        guard let date = date(month) else { return month }
        return date.formatted(.dateTime.month(.wide))
    }
}

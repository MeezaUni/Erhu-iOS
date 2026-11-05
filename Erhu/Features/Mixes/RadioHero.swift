import SwiftUI

/// Only artists represented in this station may appear in its collage.
enum RadioHeroSelection {
    static func songs(plan: RadioPlan, library: [Song]) -> [Song] {
        let byID = Dictionary(library.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = ([plan.startSongId] + plan.songIds).compactMap { byID[$0] }
        var artists = Set<String>()
        return Array(ordered.filter { song in
            let key = song.artistId > 0 ? "id:\(song.artistId)" : foldForMatch(song.artist)
            return artists.insert(key).inserted
        }.prefix(3))
    }

    /// The station owns its colour source; the currently playing song is deliberately not an input.
    static func paletteSource(plan: RadioPlan?, library: [Song], artists: [Artist]) -> ArtworkPaletteSource {
        guard let plan, let main = songs(plan: plan, library: library).first else { return .track(nil) }
        if let path = artists.first(where: { $0.id == main.artistId })?.artworkPath?.nonBlank {
            return .image(URL(fileURLWithPath: LibraryPaths.resolveImage(path)))
        }
        return .track(main.url)
    }
}

struct RadioHero: View {
    let plan: RadioPlan
    @Environment(LibraryStore.self) private var library
    @Environment(\.palette) private var palette

    private var songs: [Song] { RadioHeroSelection.songs(plan: plan, library: library.songs) }
    var body: some View {
        CollectionHeroLayout {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack {
                    if songs.count > 1 {
                        portrait(songs[1]).frame(width: width * 0.46, height: width * 0.46)
                            .position(x: width * 0.14, y: width * 0.44)
                    }
                    if songs.count > 2 {
                        portrait(songs[2]).frame(width: width * 0.46, height: width * 0.46)
                            .position(x: width * 0.86, y: width * 0.44)
                    }
                    if let main = songs.first {
                        portrait(main).frame(width: width * 0.66, height: width * 0.66)
                            .position(x: width * 0.5, y: width * 0.46)
                    }
                }
            }
            .background(LinearGradient(colors: [palette.surfaceVariant, palette.background], startPoint: .top, endPoint: .bottom))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(plan.name + " Radio").font(.largeTitle.bold()).foregroundStyle(palette.onSurface)
                Text("Selected from your library. Browse first, then choose what to play.")
                    .font(.subheadline).foregroundStyle(palette.onSurfaceVariant)
            }
            .padding(.horizontal, Spacing.heroGutter)
            .padding(.bottom, Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GeometryReader { geometry in
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: palette.background.opacity(0.18), location: 0.3),
                        .init(color: palette.background.opacity(0.75), location: 0.75),
                        .init(color: palette.background, location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                    .frame(height: geometry.size.height + 48).offset(y: -48)
                }
            }
        }
        .clipped()
    }

    private func portrait(_ song: Song) -> some View {
        FileImageView(path: library.artist(song.artistId)?.artworkPath, maxPixels: 600) {
            SongArtworkView(song: song, maxPixels: 600)
        }
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(palette.outline.opacity(0.6), lineWidth: 2) }
        .accessibilityLabel(song.artist)
    }
}

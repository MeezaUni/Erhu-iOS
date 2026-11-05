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
}

struct RadioHero: View {
    let plan: RadioPlan
    @Environment(LibraryStore.self) private var library
    @Environment(\.colorScheme) private var scheme
    @State private var sampled = LyricsPalette.fallback
    @State private var revision = 0

    private var songs: [Song] { RadioHeroSelection.songs(plan: plan, library: library.songs) }
    private var source: ArtworkPaletteSource {
        if let song = songs.first, let path = library.artist(song.artistId)?.artworkPath {
            return .image(URL(fileURLWithPath: LibraryPaths.resolveImage(path)))
        }
        return .track(songs.first?.url)
    }

    var body: some View {
        let colors = LyricsColors(sampled, scheme: scheme)
        VStack(alignment: .leading, spacing: Spacing.sm) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack {
                    if songs.count > 1 {
                        portrait(songs[1]).frame(width: width * 0.46, height: width * 0.46)
                            .position(x: width * 0.14, y: width * 0.30)
                    }
                    if songs.count > 2 {
                        portrait(songs[2]).frame(width: width * 0.46, height: width * 0.46)
                            .position(x: width * 0.86, y: width * 0.30)
                    }
                    if let main = songs.first {
                        portrait(main).frame(width: width * 0.66, height: width * 0.66)
                            .position(x: width * 0.5, y: width * 0.34)
                    }
                }
            }.aspectRatio(1.4, contentMode: .fit)
            Text(plan.name + " Radio").font(.largeTitle.bold()).foregroundStyle(colors.content)
            Text("Selected from your library. Browse first, then choose what to play.")
                .font(.subheadline).foregroundStyle(colors.secondary)
        }
        .padding(Spacing.lg)
        .background(LinearGradient(colors: colors.gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: Radius.large))
        .onReceive(NotificationCenter.default.publisher(for: ArtworkLoader.didChange)) { _ in revision += 1 }
        .task(id: "\(source)|\(revision)") {
            let next = await LyricsPaletteCache.shared.palette(for: source)
            guard !Task.isCancelled else { return }
            sampled = next
        }
    }

    private func portrait(_ song: Song) -> some View {
        FileImageView(path: library.artist(song.artistId)?.artworkPath, maxPixels: 600) {
            SongArtworkView(song: song, maxPixels: 600)
        }
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(LyricsColors(sampled, scheme: scheme).rim.opacity(0.6), lineWidth: 2) }
        .accessibilityLabel(song.artist)
    }
}

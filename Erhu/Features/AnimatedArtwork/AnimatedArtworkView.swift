import SwiftUI

struct AnimatedArtworkView: View {
    @Environment(AnimatedArtworkStore.self) private var store
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player
    @State private var query = ""

    private var albums: [Album] {
        library.albums.filter {
            (store.availability.match(for: $0) != nil || store.saved.covers[String($0.id)] != nil) &&
            (query.isBlank || SearchNormalizer.matches($0.title + " " + $0.artist, query))
        }
    }

    var body: some View {
        @Bindable var store = store
        List {
            Section {
                Toggle("Play downloaded motion covers", isOn: $store.enabled)
                Text("Check your albums, then download available motion covers for muted offline playback. Lock Screen animation depends on iOS.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.toolSectionAppearance()
            Section {
                if store.availability.checking {
                    ProgressView(value: Double(store.availability.checked), total: Double(max(store.availability.total, 1)))
                    Text("Checked \(store.availability.checked) of \(store.availability.total) albums").font(.caption)
                    Button("Stop checking", role: .cancel) { store.availability.cancel() }
                } else {
                    Button("Check all albums for motion covers") { store.availability.check(library.albums) }
                        .disabled(store.availability.checking || store.downloading != nil || store.compressing != nil || store.compressionPreview != nil)
                }
                if let message = store.availability.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("Checks availability only. Videos download when you tap Download.")
            }.toolSectionAppearance()
            Section("Lock Screen") {
                if let song = player.state.currentSong {
                    Text(song.title).font(.headline)
                }
                Text(store.enabled ? player.lockScreenMotion.status.message : "Turn on downloaded motion covers to enable Lock Screen artwork.")
                    .font(.footnote).foregroundStyle(.secondary)
                if player.lockScreenMotion.videoRequested {
                    Text("Video supplied to iOS. The system controls whether it animates.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("Keep music playing, expand the Lock Screen cover, and check that Low Power Mode and Reduce Motion are off.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Retry Lock Screen artwork") { player.refreshLockScreenArtwork() }
                    .disabled(!store.enabled || player.state.currentSong == nil || player.lockScreenMotion.status == .preparing)
            }.toolSectionAppearance()
            if let message = store.compressionMessage {
                Section { Text(message).font(.footnote) }.toolSectionAppearance()
            }
            if store.compressing != nil {
                Section {
                    ProgressView("Compressing and checking every frame…")
                    Button("Cancel compression", role: .cancel) { store.cancel() }
                }.toolSectionAppearance()
            }
            if store.downloading != nil {
                Section { Button("Cancel download", role: .cancel) { store.cancel() } }.toolSectionAppearance()
            }
            Section("Available & downloaded") {
                if albums.isEmpty { Text(store.availability.hasChecked ? "No matching motion covers yet." : "Check your albums to find available covers.").foregroundStyle(.secondary) }
                ForEach(albums) { album in
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        HStack(spacing: Spacing.md) {
                            AlbumArtworkView(albumId: album.id, maxPixels: 120)
                                .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading) {
                                Text(album.title).font(.headline)
                                Text(album.artist).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        if let status = store.status[album.id] { Text(status.label).font(.caption).foregroundStyle(.secondary) }
                        else if store.saved.covers[String(album.id)] != nil { Text("Downloaded · available offline").font(.caption).foregroundStyle(.secondary) }
                        HStack {
                            Button(store.saved.covers[String(album.id)] == nil ? "Download" : "Download again") { store.download(album) }
                                .disabled(store.availability.checking || store.downloading != nil || store.compressing != nil || store.compressionPreview != nil)
                            if store.saved.covers[String(album.id)] != nil {
                                Spacer()
                                Button("Remove", role: .destructive) { store.remove(album) }.disabled(store.downloading == album.id)
                            }
                        }.buttonStyle(.bordered)
                        if let cover = store.saved.covers[String(album.id)], cover.compressedSquare != true {
                            Button("Compress square cover…") { store.compress(album) }
                                .buttonStyle(.bordered)
                                .disabled(store.availability.checking || store.downloading != nil || store.compressing != nil || store.compressionPreview != nil)
                        }
                    }.padding(.vertical, Spacing.xs)
                }
            }.toolSectionAppearance()
        }.modifier(ToolPageAppearance())
        .searchable(text: $query, prompt: "Album or artist")
        .navigationTitle("Animated covers")
        .onDisappear { store.availability.cancel() }
        .sheet(item: Binding(get: { store.compressionPreview }, set: { if $0 == nil { store.discardCompression() } }), onDismiss: { store.discardCompression() }) { preview in
            MotionCompressionPreviewView(preview: preview)
        }
    }
}

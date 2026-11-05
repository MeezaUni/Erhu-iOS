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
                    Button(store.availability.hasChecked && store.availability.checked < store.availability.total
                           ? "Continue checking albums" : "Check all albums for motion covers") { store.availability.check(library.albums) }
                        .disabled(store.availability.checking || store.isBusy)
                    if store.availability.hasChecked && store.availability.checked < store.availability.total {
                        Button("Start a new check") { store.availability.check(library.albums, restart: true) }
                            .font(.footnote)
                            .disabled(store.isBusy)
                    }
                }
                if let message = store.availability.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("Checks availability only. Videos download when you tap Download.")
            }.toolSectionAppearance()
            downloadSection
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
                                .disabled(store.availability.checking || store.isBusy)
                            if store.saved.covers[String(album.id)] != nil {
                                Spacer()
                                Button("Remove", role: .destructive) { store.remove(album) }.disabled(store.downloading == album.id)
                            }
                        }.buttonStyle(.bordered)
                        if let cover = store.saved.covers[String(album.id)], cover.compressedSquare != true {
                            Button("Compress square cover…") { store.compress(album) }
                                .buttonStyle(.bordered)
                                .disabled(store.availability.checking || store.isBusy)
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

    private var downloadSection: some View {
        Section("Downloads") {
            if store.downloads.isRunning {
                ProgressView(value: Double(store.downloads.completed), total: Double(max(store.downloads.total, 1)))
                Text("Downloading \(min(store.downloads.completed + 1, store.downloads.total)) of \(store.downloads.total)")
                    .font(.subheadline.weight(.semibold))
                if let album = store.downloads.current { Text(album.title).font(.footnote).foregroundStyle(.secondary) }
                Text("\(store.downloads.saved) saved · \(store.downloads.failed) failed")
                    .font(.caption).foregroundStyle(.secondary)
                Button(store.downloads.isStopping ? "Stopping…" : "Stop downloads", role: .cancel) { store.downloads.stop() }
                    .disabled(store.downloads.isStopping)
            } else {
                let count = store.pendingDownloads(in: library.albums).count
                Button { store.downloadAll(library.albums) } label: {
                    Label("Download all available (\(count))", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentShape(Rectangle())
                }
                .disabled(count == 0 || store.isBusy || store.availability.checking)
            }
            if let message = store.downloads.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        } footer: {
            Text("Downloads checked covers one at a time. Existing downloads are skipped. Keep Erhu open; Stop keeps completed covers.")
        }
        .toolSectionAppearance()
    }

}

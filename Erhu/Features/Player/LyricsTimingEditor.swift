import SwiftUI

struct LyricsTimingEditor: View {
    let song: Song
    let lyrics: SongLyrics
    let context: LyricsTimingContext
    let preferences: LyricsTimingPreferences
    @Environment(PlayerController.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var offset: Int64 = 0
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.sm) {
                Text(song.title).font(.headline).lineLimit(1)
                Text("Move lyrics earlier if they arrive late, or later if they arrive too soon.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                    Text("Earlier")
                    Slider(value: Binding(get: { Double(offset) }, set: { offset = Int64($0.rounded()) }),
                           in: -30_000...30_000, step: 50)
                    Text("Later")
                }.font(.caption)
                HStack {
                    Stepper(value: $offset, in: -30_000...30_000, step: 50) {
                        HStack {
                            TextField("Offset", value: $offset, format: .number.grouping(.never))
                                .multilineTextAlignment(.trailing).frame(width: 95)
                                .textFieldStyle(.roundedBorder)
                            Text("ms").foregroundStyle(.secondary)
                        }
                    }
                    Button("Reset") { offset = 0 }
                }
                let previous = preferences.previous(for: context)
                if !previous.isEmpty {
                    Menu("Use timing from another source") {
                        ForEach(previous) { item in
                            Button("\(item.label) · \(item.offsetMs) ms") { offset = item.offsetMs }
                        }
                    }.font(.caption)
                }
                Button {
                    if player.state.isPlaying { player.pause() } else { player.play() }
                } label: {
                    Label(player.state.isPlaying ? "Pause preview" : "Preview timing",
                          systemImage: player.state.isPlaying ? "pause.fill" : "play.fill")
                }
                .modifier(PaletteFilledButton())
                .disabled(player.state.currentSong?.id != song.id)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                if case .synced(let lines)? = lyrics.parsed, let parsed = lyrics.parsed {
                    SyncedLyricsView(lyrics: parsed, lines: lines, offsetMs: offset.clamped(-30_000, 30_000))
                }
            }
            .padding(.horizontal)
            .modifier(ToolPageAppearance())
            .navigationTitle("Lyrics timing").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try preferences.save(offset, for: context); dismiss() }
                        catch { error = "Couldn’t save the timing. Check available storage and try again." }
                    }
                }
            }
        }
        .onAppear { offset = preferences.offset(for: context) }
        .onChange(of: offset) { _, value in preferences.preview(value, for: context) }
        .onDisappear { preferences.endPreview(for: context) }
    }
}

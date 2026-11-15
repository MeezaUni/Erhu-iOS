import SwiftUI

/// Drag a playlist's songs into a new order. Repeated songs move independently: each row is one
/// playlist entry, identified by its position, which never changes. The new order is saved only
/// when the user taps Done, and only if the playlist did not change in the meantime.
struct PlaylistReorderSheet: View {
    let playlistId: Int64
    let entries: [PlaylistEntry]
    var onSaved: () -> Void = {}
    @Environment(LibraryStore.self) private var library
    @Environment(LibraryActions.self) private var actions
    @Environment(\.dismiss) private var dismiss
    @State private var order: [PlaylistEntry] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(order, id: \.position) { entry in
                    HStack(spacing: Spacing.md) {
                        SongArtworkView(song: entry.song, maxPixels: 120)
                            .frame(width: ArtworkSize.compact, height: ArtworkSize.compact)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.song.title).lineLimit(1)
                            Text(entry.song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                .onMove { source, destination in order.move(fromOffsets: source, toOffset: destination) }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { save() }.bold() }
            }
        }
        .onAppear { if order.isEmpty { order = entries } }
    }

    private func save() {
        let before = entries.map(\.position)
        let after = order.map(\.position)
        do {
            if try library.database.reorderPlaylist(playlistId, from: before, to: after) {
                onSaved()
            } else {
                actions.show(String(localized: "The playlist changed while you were reordering it. Try again."))
            }
        } catch {
            actions.show(String(localized: "Couldn't save the new order: \(error.localizedDescription)"))
        }
        dismiss()
    }
}

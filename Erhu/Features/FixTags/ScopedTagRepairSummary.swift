import SwiftUI

/// Results stay with the collection that requested them; unrelated queue entries are excluded.
struct ScopedTagRepairSummary: View {
    let songs: [Song]
    @Environment(FixTagsStore.self) private var store
    @State private var showingResults = false
    @State private var detail: RepairItem?
    private var items: [RepairItem] {
        let ids = Set(songs.map(\.id)).intersection(store.inPlaceScope)
        return store.queue.filter { ids.contains($0.id) }
    }
    var body: some View {
        if !items.isEmpty {
            let completed = items.filter { !$0.status.toProcess && $0.status != .fixing }.count
            Button { showingResults = true } label: {
                HStack {
                    if store.isRunning { ProgressView() }
                    Label(store.isRunning ? "Fixing tags · \(completed) of \(items.count)" : "Tag repair results · \(items.count) songs", systemImage: "wand.and.stars")
                    Spacer()
                    Image(systemName: "chevron.right")
                }.font(.footnote).padding(Spacing.lg)
            }.buttonStyle(.plain)
            .sheet(isPresented: $showingResults) {
                NavigationStack {
                    List(items) { item in
                        Button { detail = item } label: {
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text(item.song.title).font(.headline)
                                Text(item.status.label).font(.subheadline)
                                if let reason = item.reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                            }
                        }.buttonStyle(.plain)
                    }
                    .navigationTitle("Tag repair results").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingResults = false } } }
                    .sheet(item: $detail) { RepairItemDetail(item: $0) }
                }
            }
        }
    }
}

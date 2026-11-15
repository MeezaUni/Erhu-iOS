import SwiftUI

/// Music Server: connect to Erhu Server (or another Subsonic-compatible server) on your own
/// computer or NAS, then stream from it or download songs to this device.
struct MusicServerView: View {
    @Environment(ServerStore.self) private var servers
    @State private var addingServer = false
    @State private var confirmingRemoval: ServerAccount?
    @State private var cacheSize: Int64 = 0

    var body: some View {
        @Bindable var servers = servers
        List {
            if servers.accounts.isEmpty {
                Section {
                    Label("Stream or download from your own music server", systemImage: "server.rack").font(.headline)
                    Text("Run Erhu Server on your computer or NAS, then connect to it here. Your music stays on your own devices; nothing goes through an Erhu service.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button { addingServer = true } label: { Label("Add server", systemImage: "plus") }
                    Link(destination: Self.setupGuide) { Label("How to set up Erhu Server", systemImage: "book") }
                }.toolSectionAppearance()
            } else if let account = servers.selected {
                Section {
                    if servers.accounts.count > 1 {
                        Picker("Server", selection: $servers.selectedId) {
                            ForEach(servers.accounts) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                    LabeledContent("Server", value: account.name)
                    LabeledContent("Address", value: account.baseURL.absoluteString)
                    LabeledContent("User", value: account.username)
                }.toolSectionAppearance()
                Section("Browse") {
                    NavigationLink { ServerSearchView(account: account) } label: { Label("Search", systemImage: "magnifyingglass") }
                    NavigationLink { ServerAlbumListView(account: account, type: "alphabeticalByName", title: String(localized: "Albums")) } label: {
                        Label("Albums", systemImage: "square.stack")
                    }
                    NavigationLink { ServerAlbumListView(account: account, type: "newest", title: String(localized: "Recently added")) } label: {
                        Label("Recently added", systemImage: "clock")
                    }
                    NavigationLink { ServerAlbumListView(account: account, type: "random", title: String(localized: "Random albums")) } label: {
                        Label("Random albums", systemImage: "shuffle")
                    }
                    NavigationLink { ServerArtistsView(account: account) } label: { Label("Artists", systemImage: "music.mic") }
                    NavigationLink { ServerPlaylistsView(account: account) } label: { Label("Playlists", systemImage: "music.note.list") }
                }.toolSectionAppearance()
                Section {
                    Picker("Streaming quality", selection: $servers.quality) {
                        ForEach(StreamQuality.allCases) { Text($0.label).tag($0) }
                    }
                    Text("Original plays the server's file unchanged. The MP3 settings use less data; the server converts each song, so it can take a little longer to start.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Streaming cache", value: ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                    Button("Clear streaming cache") {
                        ServerStream.shared.clearCache()
                        cacheSize = ServerStream.shared.cacheSize()
                    }
                } header: { Text("Streaming") } footer: {
                    Text("Streamed songs are fetched to a cache just before they play, and the next songs are fetched ahead. They don't join your library; download a song to keep it.")
                }.toolSectionAppearance()
                if !servers.downloads.isEmpty { downloadsSection }
                Section {
                    Button { addingServer = true } label: { Label("Add another server", systemImage: "plus") }
                    Link(destination: Self.setupGuide) { Label("How to set up Erhu Server", systemImage: "book") }
                    Button(role: .destructive) { confirmingRemoval = account } label: { Label("Remove this server", systemImage: "trash") }
                }.toolSectionAppearance()
            }
        }
        .navigationTitle("Music Server")
        .sheet(isPresented: $addingServer) { AddServerSheet() }
        .confirmationDialog(confirmingRemoval.map { String(localized: "Remove “\($0.name)”?") } ?? "",
                            isPresented: Binding(get: { confirmingRemoval != nil }, set: { if !$0 { confirmingRemoval = nil } }),
                            titleVisibility: .visible, presenting: confirmingRemoval) { account in
            Button(String(localized: "Remove server"), role: .destructive) { servers.remove(account) }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { _ in
            Text("Songs you downloaded stay on this device. The saved password is deleted.")
        }
        .task { cacheSize = ServerStream.shared.cacheSize() }
    }

    private var downloadsSection: some View {
        Section {
            ForEach(servers.downloads.reversed()) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.song.title).lineLimit(1)
                        Text(item.message ?? item.song.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    switch item.state {
                    case .waiting: Image(systemName: "clock").foregroundStyle(.secondary).accessibilityLabel("Waiting")
                    case .downloading: ProgressView()
                    case .saved: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Saved")
                    case .alreadySaved: Image(systemName: "checkmark.circle").foregroundStyle(.secondary).accessibilityLabel("Already on this device")
                    case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityLabel("Not saved")
                    }
                }
            }
            if servers.isDownloading {
                Button("Cancel downloads", role: .destructive) { servers.cancelDownloads() }
            } else {
                Button("Clear list") { servers.clearFinishedDownloads() }
            }
        } header: { Text("Downloads") } footer: {
            Text("Downloaded songs are saved in the Erhu folder under From Server and join your library.")
        }.toolSectionAppearance()
    }

    static let setupGuide = URL(string: "https://github.com/MeezaUni/Erhu-iOS/blob/test-server-option/Server/README.md")!
}

/// Name, address, username and password of a new server; checked with the server before saving.
struct AddServerSheet: View {
    @Environment(ServerStore.self) private var servers
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var connecting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Address, e.g. http://192.168.1.20:4533", text: $address)
                        .keyboardType(.URL).textContentType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Username", text: $username)
                        .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password).textContentType(.password)
                    TextField("Name (optional)", text: $name)
                } footer: {
                    Text("Use the address Erhu Server shows on your computer. Away from home, use an HTTPS address, for example through Tailscale. Erhu Server and Navidrome work, and so do other Subsonic-compatible servers.")
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if connecting { ProgressView() } else {
                        Button("Connect") { connect() }.disabled(address.isEmpty || username.isEmpty || password.isEmpty)
                    }
                }
            }
            .interactiveDismissDisabled(connecting)
        }
    }

    private func connect() {
        connecting = true
        error = nil
        Task {
            do {
                _ = try await servers.add(name: name, address: address, username: username, password: password)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            connecting = false
        }
    }
}

/// Loads [load] when shown (and on pull to refresh) and shows its result, a spinner, or the error with Try again.
struct ServerContent<Value, Content: View>: View {
    let load: () async throws -> Value
    @ViewBuilder let content: (Value) -> Content
    @State private var value: Value?
    @State private var error: String?

    var body: some View {
        Group {
            if let value {
                content(value)
            } else if let error {
                VStack(spacing: Spacing.md) {
                    Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(error).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Try again") { Task { await reload() } }.buttonStyle(.bordered)
                }
                .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { if value == nil { await reload() } }
        .refreshable { await reload() }
    }

    private func reload() async {
        do {
            value = try await load()
            error = nil
        } catch is CancellationError {
        } catch let failure as URLError where failure.code == .cancelled {
        } catch {
            if value == nil { self.error = error.localizedDescription }
        }
    }
}

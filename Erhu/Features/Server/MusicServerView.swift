import SwiftUI

/// Music Server: connect to Erhu Server (or another Subsonic-compatible server) on your own
/// computer or NAS, then stream from it or download songs to this device.
struct MusicServerView: View {
    @Environment(ServerStore.self) private var servers
    @State private var addingServer = false
    @State private var confirmingRemoval: ServerAccount?
    @State private var cacheSize: Int64 = 0
    @State private var editingRemote: ServerAccount?
    @State private var remoteDraft = ""
    @State private var remoteError: String?

    var body: some View {
        @Bindable var servers = servers
        List {
            if servers.accounts.isEmpty {
                Section {
                    Label("Stream or download from your own music server", systemImage: "server.rack").font(.headline)
                    Text("Run Erhu Server on your computer or NAS, then connect to it here. Your music stays on your own devices; nothing goes through an Erhu service.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("Once connected, the server's music appears in Search, on Library and on Home, next to your own.")
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
                    LabeledContent("Home address", value: account.baseURL.absoluteString)
                    Button { remoteDraft = account.remoteURL?.absoluteString ?? ""; editingRemote = account } label: {
                        LabeledContent("Away address", value: account.remoteURL?.absoluteString ?? String(localized: "Not set"))
                    }
                    .foregroundStyle(.primary)
                    if account.remoteURL != nil {
                        LabeledContent("Connected through", value: servers.usingAway.contains(account.id)
                                       ? String(localized: "Away address") : String(localized: "Home address"))
                    }
                    LabeledContent("User", value: account.username)
                } footer: {
                    Text("The server's music appears in Search, on Library and on Home, next to your own.")
                }.toolSectionAppearance()
                Section {
                    Picker("Streaming quality", selection: $servers.quality) {
                        ForEach(StreamQuality.allCases) { Text($0.label).tag($0) }
                    }
                    Text("Automatic plays the original file at home, and a smaller MP3 away from home or on mobile data when the server can convert (Erhu Server with ffmpeg). Original always plays the server's file unchanged. The MP3 settings use less data; the server converts each song.")
                        .font(.caption).foregroundStyle(.secondary)
                    if servers.quality == .automatic, let converts = servers.convertsToMP3[account.id] {
                        Label(converts ? LocalizedStringKey("This server converts to MP3.") : LocalizedStringKey("This server can't convert yet, so Automatic plays original files. In Erhu Server, install ffmpeg."),
                              systemImage: converts ? "checkmark.circle" : "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
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
        .alert("Away address", isPresented: Binding(get: { editingRemote != nil }, set: { if !$0 { editingRemote = nil } }), presenting: editingRemote) { account in
            TextField(text: $remoteDraft, prompt: Text(verbatim: "https://computer.tailnet.ts.net")) { Text("Away address") }
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Save") {
                let draft = remoteDraft
                Task {
                    do { try await servers.setRemote(draft, for: account) } catch { remoteError = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The HTTPS address Erhu Server shows under “Listen away from home”. Leave it empty to use only your home address.")
        }
        .alert("Couldn't save the away address", isPresented: Binding(get: { remoteError != nil }, set: { if !$0 { remoteError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(remoteError ?? "") }
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
    /// Filled in from a pairing link (the QR code shown by the Erhu Server app).
    var invite: ServerInvite?
    @Environment(ServerStore.self) private var servers
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var remote = ""
    @State private var username = ""
    @State private var password = ""
    @State private var connecting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Address", text: $address, prompt: Text(verbatim: "http://192.168.1.20:4533"))
                        .keyboardType(.URL).textContentType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Username", text: $username)
                        .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password).textContentType(.password)
                    TextField("Name (optional)", text: $name)
                } footer: {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("With the Erhu Server app on your computer, scan its QR code with the iPhone's Camera to fill this in.")
                        Text("Use the address Erhu Server shows on your computer. Erhu Server and Navidrome work, and so do other Subsonic-compatible servers.")
                    }
                }
                Section {
                    TextField("Away address (optional)", text: $remote, prompt: Text(verbatim: "https://computer.tailnet.ts.net"))
                        .keyboardType(.URL).textContentType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Away from home") } footer: {
                    Text("The HTTPS address Erhu Server shows under “Listen away from home”. Erhu uses your home address on your Wi-Fi and this one everywhere else.")
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // An icon keeps the button whole in every language (the word was cut to "Ca…").
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.body.weight(.semibold)) }
                        .accessibilityLabel("Cancel")
                        .disabled(connecting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if connecting { ProgressView() } else {
                        Button("Connect") { connect() }.disabled(address.isEmpty || username.isEmpty || password.isEmpty)
                    }
                }
            }
            .interactiveDismissDisabled(connecting)
        }
        .onAppear {
            guard let invite, address.isEmpty else { return }
            address = invite.address
            remote = invite.remote
            username = invite.username
            name = invite.name
        }
    }

    private func connect() {
        connecting = true
        error = nil
        Task {
            do {
                _ = try await servers.add(name: name, address: address, remote: remote, username: username, password: password)
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

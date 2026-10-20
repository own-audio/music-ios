import MusicLibrary
import SwiftUI

/// One server's connection: which address is in use, how it is picked, and every address it
/// is known by; its name, and removing it, as in the podcasts app.
struct ServerDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let serverId: UUID
    @State private var isRenaming = false
    @State private var newName = ""
    @State private var confirmRemove = false
    @State private var pickingLibrary = false
    @State private var isAdding = false
    @State private var newAddress = ""
    @State private var errorMessage: String?
    @State private var isSigningIn = false
    /// own.audio's optional parts this server has switched on (`identify_library`, `billing`).
    @State private var modules: [String: Bool] = [:]

    private var server: ServerRecord? { model.servers.first { $0.id == serverId } }

    var body: some View {
        if let server {
            List {
                // The library shows one server at a time; this one, from here.
                if server.id != model.activeServerId {
                    Section {
                        Button {
                            Haptics.selection()
                            model.selectServer(id: server.id)
                        } label: {
                            Label("Use This Server", systemImage: "checkmark.circle")
                        }
                        .accessibilityIdentifier("serverDetail.use")
                    } footer: {
                        Text("The library shows the selected server.")
                    }
                }

                Section {
                    statusRow(server)
                    Button {
                        Task { await model.checkNow(id: server.id) }
                    } label: {
                        HStack {
                            Text("Check Now")
                            Spacer()
                            if model.checkingConnections.contains(server.id) { ProgressView() }
                        }
                    }
                    .disabled(model.checkingConnections.contains(server.id))
                    .accessibilityIdentifier("serverDetail.check")
                    checkResult(server)
                } footer: {
                    Text(footer(server))
                }

                Section {
                    if model.signInRefused.contains(server.id) {
                        Label("The server no longer accepts this sign-in.", systemImage: "person.crop.circle.badge.exclamationmark")
                            .foregroundStyle(.orange)
                    }
                    Button("Sign In Again") { isSigningIn = true }
                        .accessibilityIdentifier("serverDetail.signInAgain")

                } header: {
                    Text("Account")
                } footer: {
                    Text("Signed in as \(server.auth.username). Downloads and the library on this iPhone stay as they are.")
                }

                // The account's family and signed-in devices, on its server's page as in the
                // podcasts app.
                if server.kind == .ownAudio, case .ownAudio = server.auth {
                    Section {
                        if server.id == model.activeServerId, model.household != nil {
                            NavigationLink { HouseholdView() } label: { Label("Family", systemImage: "person.3") }
                                .accessibilityIdentifier("serverDetail.family")
                        }
                        NavigationLink { DevicesView(serverId: server.id) } label: { Label("Devices", systemImage: "iphone.gen3") }
                            .accessibilityIdentifier("serverDetail.devices")
                    }
                }

                Section {
                    LabeledContent("Server") {
                        HStack(spacing: Theme.Spacing.sm) {
                            ServerKindIcon(kind: server.kind, size: 22)
                            Text(server.kind.title)
                        }
                    }
                    LabeledContent("Talks Through", value: server.connectionTitle)
                        .accessibilityIdentifier("serverDetail.protocol")
                    Button {
                        newName = server.displayName
                        isRenaming = true
                    } label: {
                        LabeledContent("Name", value: server.displayName)
                    }
                    .accessibilityIdentifier("serverDetail.name")
                    if server.kind == .jellyfin {
                        Button { pickingLibrary = true } label: { Text("Music Library…") }
                            .accessibilityIdentifier("serverDetail.library")
                    }
                } footer: {
                    if server.kind == .ownAudio, case .subsonic = server.auth {
                        Text("Added before this app spoke own.audio's own API, or from an older server. Sign in again to use it: the library on this iPhone then stays up to date within seconds.")
                    }
                }

                Section("Connection") {
                    Picker("Use", selection: Binding(
                        get: { mode(server) },
                        set: { change(server, to: $0) }
                    )) {
                        Text("Automatic").tag(Optional<URL>.none)
                        ForEach(server.candidateAddresses) { address in
                            Text(address.url.absoluteString).tag(Optional(address.url))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("serverDetail.mode")
                }

                Section {
                    ForEach(server.candidateAddresses) { address in
                        addressRow(address)
                            .swipeActions {
                                if address.origin != .added {
                                    Button(role: .destructive) {
                                        remove(address, from: server)
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                            }
                    }
                    Button {
                        newAddress = ""
                        isAdding = true
                    } label: {
                        Label("Add Address", systemImage: "plus")
                    }
                    .accessibilityIdentifier("serverDetail.add")
                } header: {
                    Text("Addresses")
                } footer: {
                    Text("Add the server's address on your home network, a VPN such as Tailscale, or a second public name. On each network the app uses the fastest one that answers as this server.")
                }

                if modules["identify_library"] == true, let client = model.ownAudioSource(serverId: server.id)?.client {
                    Section {
                        NavigationLink {
                            IdentifyRunsView(client: client, charges: modules["billing"] == true)
                        } label: {
                            Label("Identify Library", systemImage: "waveform.badge.magnifyingglass")
                        }
                        .accessibilityIdentifier("serverDetail.identify")
                    } footer: {
                        Text("Lets MusicBrainz name your songs and albums on the server. Nothing changes until you accept it, and the files stay as they are.")
                    }
                }

                Section {
                    catalogueRow(server)
                    Button("Update Now") {
                        Task { await model.syncCatalogues(force: true) }
                    }
                    .disabled(model.syncingCatalogues.contains(server.id) || model.isOffline)
                    .accessibilityIdentifier("serverDetail.syncCatalogue")
                } header: {
                    Text("Library on This iPhone")
                } footer: {
                    Text("A list of everything on the server, without the music itself, so albums open and the library can be browsed offline. Updated in the background, on Wi-Fi.")
                }

                Section {
                    Button("Remove Server", role: .destructive) { confirmRemove = true }
                        .accessibilityIdentifier("serverDetail.remove")
                }
            }
            // The app's pink read as red beside the status lines here; the buttons take the
            // text colour, and red stays for removing and for a refused sign-in.
            .tint(.primary)
            .sheet(isPresented: $isSigningIn) {
                SignInAgainView(server: server)
            }
            .sheet(isPresented: $pickingLibrary) {
                LibraryPickerView(server: server)
            }
            .navigationTitle(server.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .task { await model.chooseAddresses() }
            .task(id: server.id) {
                guard server.kind == .ownAudio, let client = model.ownAudioSource(serverId: server.id)?.client else { return }
                modules = (try? await client.modules()) ?? [:]
            }
            .alert("Add Address", isPresented: $isAdding) {
                TextField("http://192.168.1.20:4533", text: $newAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Cancel", role: .cancel) {}
                Button("Add") { add(newAddress, to: server) }
            }
            .alert("Couldn't Add the Address", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .alert("Rename", isPresented: $isRenaming) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    model.perform { try await model.renameServer(id: server.id, to: name) }
                }
            }
            .confirmationDialog("Remove \(server.displayName)?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    let id = server.id
                    dismiss()
                    model.perform { try await model.removeServer(id: id) }
                }
            } message: {
                Text("Its downloads leave this iPhone. Nothing changes on the server.")
            }
        }
    }

    @ViewBuilder
    private func catalogueRow(_ server: ServerRecord) -> some View {
        if model.syncingCatalogues.contains(server.id) {
            HStack {
                Text("Updating…")
                Spacer()
                ProgressView()
            }
        } else if let catalogue = model.catalogues[server.id] {
            VStack(alignment: .leading, spacing: 2) {
                Text("Songs: \(catalogue.snapshot.songs.count) · Albums: \(catalogue.snapshot.albums.count)")
                Text("Updated \(catalogue.snapshot.syncedAt.formatted(.relative(presentation: .named)))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("serverDetail.catalogue")
        } else if let error = model.catalogueErrors[server.id] {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        } else {
            Text("Not yet updated")
                .foregroundStyle(.secondary)
        }
    }

    /// What the last "Check Now" found, so the button visibly did something.
    @ViewBuilder
    private func checkResult(_ server: ServerRecord) -> some View {
        if !model.checkingConnections.contains(server.id), let check = model.connectionChecks[server.id] {
            let when = check.at.formatted(date: .omitted, time: .shortened)
            Group {
                switch check.status {
                case .ok:
                    Label("Checked at \(when): the server answers and accepts the sign-in.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .rejected:
                    Label("Checked at \(when): the server refuses the sign-in. Sign in again below.", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                case .unreachable:
                    Label("Checked at \(when): no address of the server answers.", systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.orange)
                }
            }
            .font(.footnote)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("serverDetail.checkResult")
        }
    }

    @ViewBuilder
    private func statusRow(_ server: ServerRecord) -> some View {
        switch model.connectionStates[server.id] {
        case .connected(let url):
            let scope = server.candidateAddresses.first { $0.url == url }?.scope ?? AddressScope.infer(url)
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connected · \(scope.title)")
                    Text(url.absoluteString).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("serverDetail.status")
        case .unreachable:
            Label("No address answers right now", systemImage: "wifi.exclamationmark")
                .foregroundStyle(.orange)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("serverDetail.status")
        case .checking, nil:
            Label("Checking…", systemImage: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("serverDetail.status")
        }
    }

    private func addressRow(_ address: ServerAddress) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(address.url.absoluteString).lineLimit(1)
            Text("\(address.scope.title) · \(address.origin.title)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func footer(_ server: ServerRecord) -> String {
        switch server.kind {
        case .subsonic:
            String(localized: "Subsonic servers don't say which addresses they have, so add them here; the app checks each one with your sign-in.")
        case .jellyfin, .ownAudio:
            String(localized: "The server tells the app its addresses and an identity, so an address that answers as a different server is never used.")
        }
    }

    private func mode(_ server: ServerRecord) -> URL? {
        if case .fixed(let url) = server.connection { url } else { nil }
    }

    private func change(_ server: ServerRecord, to url: URL?) {
        var updated = server
        updated.connection = url.map { .fixed($0) } ?? .automatic
        Task {
            try? await model.update(updated)
            await model.chooseAddresses()
        }
    }

    private func add(_ text: String, to server: ServerRecord) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: withScheme), url.host() != nil else {
            errorMessage = String(localized: "That doesn't look like a server address.")
            return
        }
        var updated = server
        updated.addresses.append(ServerAddress(url: url, origin: .user))
        Task {
            try? await model.update(updated)
            await model.chooseAddresses()
        }
    }

    private func remove(_ address: ServerAddress, from server: ServerRecord) {
        var updated = server
        updated.addresses.removeAll { $0.url == address.url }
        if case .fixed(let url) = updated.connection, url == address.url { updated.connection = .automatic }
        Task {
            try? await model.update(updated)
            await model.chooseAddresses()
        }
    }
}

extension AddressScope {
    var title: String {
        switch self {
        case .lan: String(localized: "Home network")
        case .vpn: String(localized: "VPN")
        case .public: String(localized: "Internet")
        }
    }
}

extension ServerAddress.Origin {
    var title: String {
        switch self {
        case .added: String(localized: "added with")
        case .server: String(localized: "from the server")
        case .user: String(localized: "added by you")
        }
    }
}

/// The saved server's sign-in, entered again: its username kept, the password asked for.
private struct SignInAgainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let server: ServerRecord
    @State private var username = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var providerError: String?
    @State private var providers: (apple: Bool, google: Bool) = (false, false)

    var body: some View {
        NavigationStack {
            Form {
                if providers.apple || providers.google {
                    Section {
                        if providers.apple {
                            AppleSignInButton(address: server.host.absoluteString, name: server.displayName, isWorking: $isWorking,
                                              errorMessage: $providerError, onSignedIn: { dismiss() }, replacing: server.id)
                        }
                        if providers.google {
                            GoogleSignInButton(address: server.host.absoluteString, name: server.displayName, isWorking: $isWorking,
                                               errorMessage: $providerError, onSignedIn: { dismiss() }, replacing: server.id)
                        }
                    } footer: {
                        Text("If you signed up with Apple or Google, sign in the same way.")
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                Section {
                    TextField(server.kind == .ownAudio ? "Email" : "Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("signInAgain.username")
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .accessibilityIdentifier("signInAgain.password")
                } footer: {
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(server.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView()
                    } else {
                        Button("Sign In") { signIn() }
                            .disabled(username.isEmpty || password.isEmpty)
                            .accessibilityIdentifier("signInAgain.submit")
                    }
                }
            }
            .onAppear { username = server.auth.username }
            .task {
                if server.kind == .ownAudio { providers = await model.ownAudioProviders(serverId: server.id) }
            }
            .sheet(item: model.pendingTwoFactorBinding) { _ in
                TwoFactorView { dismiss() }
            }
        }
    }

    private func signIn() {
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                try await model.signInAgain(serverId: server.id, username: username.trimmingCharacters(in: .whitespaces), password: password)
                dismiss()
            } catch {
                if !error.isTwoFactorNeeded { errorMessage = error.localizedDescription }
            }
        }
    }
}

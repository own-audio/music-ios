import MusicLibrary
import SwiftUI

/// One server's connection: which address is in use, how it is picked, and every address it
/// is known by.
struct ServerDetailView: View {
    @Environment(AppModel.self) private var model
    let serverId: UUID
    @State private var isAdding = false
    @State private var newAddress = ""
    @State private var errorMessage: String?

    private var server: ServerRecord? { model.servers.first { $0.id == serverId } }

    var body: some View {
        if let server {
            List {
                Section {
                    statusRow(server)
                    Button("Check Now") {
                        Task { await model.chooseAddresses() }
                    }
                    .accessibilityIdentifier("serverDetail.check")
                } footer: {
                    Text(footer(server))
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
            }
            .navigationTitle(server.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .task { await model.chooseAddresses() }
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

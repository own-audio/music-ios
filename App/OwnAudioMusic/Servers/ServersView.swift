import MusicLibrary
import SwiftUI
import UIKit

/// Every configured server: pick the one to browse, check, rename or remove.
struct ServersView: View {
    @Environment(AppModel.self) private var model
    @State private var isAdding = false
    @State private var renaming: ServerRecord?
    @State private var newName = ""
    @State private var statuses: [UUID: ConnectionStatus] = [:]
    @State private var checking: Set<UUID> = []
    @State private var errorMessage: String?
    @State private var pickingLibrary: ServerRecord?
    @State private var showingDetail: UUID?

    var body: some View {
        List {
            Section {
                ForEach(model.serversInOrder) { server in
                    row(server)
                }
            } footer: {
                Text("The library shows the selected server. Music from any server can stay in the queue.")
            }

            Section {
                Button {
                    isAdding = true
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
                .accessibilityIdentifier("servers.add")
            }
        }
        .navigationTitle("Servers")
        .sheet(isPresented: $isAdding) {
            NavigationStack { AddServerView() }
        }
        .sheet(item: $pickingLibrary) { server in
            LibraryPickerView(server: server)
        }
        .navigationDestination(item: $showingDetail) { id in
            ServerDetailView(serverId: id)
        }
        .alert("Rename Server", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                guard let server = renaming else { return }
                let name = newName.trimmingCharacters(in: .whitespaces)
                renaming = nil
                guard !name.isEmpty else { return }
                Task { try? await model.renameServer(id: server.id, to: name) }
            }
        }
        .alert("Couldn't Remove Server", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func row(_ server: ServerRecord) -> some View {
        Button {
            Haptics.selection()
            model.selectServer(id: server.id)
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                ServerKindIcon(kind: server.kind, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.displayName).foregroundStyle(.primary)
                    Text(server.connectionTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("servers.protocol.\(server.displayName)")
                    Text("\(server.auth.username) · \(server.host.absoluteString)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    statusText(server.id)
                }
                Spacer()
                if server.id == model.activeServerId {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Selected")
                }
                Button {
                    showingDetail = server.id
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Connection")
                .accessibilityIdentifier("servers.info.\(server.displayName)")
            }
        }
        .accessibilityIdentifier("servers.row.\(server.displayName)")
        .swipeActions {
            Button(role: .destructive) {
                remove(server)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .contextMenu {
            Button {
                check(server)
            } label: {
                Label("Check Connection", systemImage: "antenna.radiowaves.left.and.right")
            }
            if server.kind == .jellyfin {
                Button {
                    pickingLibrary = server
                } label: {
                    Label("Music Library…", systemImage: "music.note.house")
                }
            }
            Button {
                newName = server.displayName
                renaming = server
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                remove(server)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func statusText(_ id: UUID) -> some View {
        if checking.contains(id) {
            Text("Checking…").font(.caption).foregroundStyle(.secondary)
        } else if let status = statuses[id] {
            switch status {
            case .ok: Label("Connected", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            case .rejected: Label("Sign-in rejected", systemImage: "xmark.circle.fill").font(.caption).foregroundStyle(.red)
            case .unreachable: Label("Unreachable", systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func check(_ server: ServerRecord) {
        checking.insert(server.id)
        Task {
            statuses[server.id] = await model.checkConnection(id: server.id)
            checking.remove(server.id)
        }
    }

    private func remove(_ server: ServerRecord) {
        Task {
            do {
                try await model.removeServer(id: server.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

extension ServerKind {
    var title: String {
        switch self {
        case .subsonic: "Subsonic"
        case .jellyfin: "Jellyfin"
        case .ownAudio: "own.audio"
        }
    }
}

extension ServerRecord {
    /// How the app talks to it: an own.audio server added before its own API, or on an older
    /// server, goes through its Subsonic API.
    var connectionTitle: String {
        switch (kind, auth) {
        case (.ownAudio, .ownAudio): String(localized: "own.audio · own API")
        case (.ownAudio, _): String(localized: "own.audio · Subsonic API")
        case (.jellyfin, _): String(localized: "Jellyfin API")
        case (.subsonic, _): String(localized: "Subsonic API")
        }
    }
}

/// The server's kind at a glance: own.audio's logo, Jellyfin's (CC BY-SA 4.0, marking a
/// Jellyfin server, as its branding guide allows), OpenSubsonic's (Apache-2.0) for Subsonic
/// servers — one colour, drawn in the text colour.
struct ServerKindIcon: View {
    let kind: ServerKind
    var size: CGFloat = 28

    var body: some View {
        Group {
            switch kind {
            case .ownAudio:
                Image("ServerLogo").resizable().scaledToFit()
            case .subsonic:
                Image("OpenSubsonicLogo").resizable().scaledToFit().padding(size * 0.06)
                    .foregroundStyle(.primary)
            case .jellyfin:
                Image("JellyfinLogo").resizable().scaledToFit().padding(size * 0.08)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityLabel(Text(kind.title))
    }
}

extension ServerKind {
    /// The same for a menu row. Menus draw a custom picture at its own size, so it is drawn
    /// here at the size of a menu's symbols.
    @MainActor
    func menuIcon(dark: Bool, side: CGFloat = 22) -> Image {
        let name = switch self {
        case .ownAudio: "ServerLogo"
        case .jellyfin: "JellyfinLogo"
        case .subsonic: "OpenSubsonicLogo"
        }
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        guard var source = UIImage(named: name, in: nil, compatibleWith: traits) else {
            return Image(systemName: "music.note.house")
        }
        // One colour: drawn as the menu's text would be.
        if self == .subsonic { source = source.withTintColor(dark ? .white : .black, renderingMode: .alwaysOriginal) }
        let scale = min(side / source.size.width, side / source.size.height)
        let drawn = CGSize(width: source.size.width * scale, height: source.size.height * scale)
        let box = CGSize(width: side, height: side)
        let small = UIGraphicsImageRenderer(size: box).image { _ in
            source.draw(in: CGRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2, width: drawn.width, height: drawn.height))
        }
        return Image(uiImage: small).renderingMode(.original)
    }
}

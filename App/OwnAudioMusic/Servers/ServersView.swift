import MusicLibrary
import SwiftUI
import UIKit

/// The servers, listed in Settings as in the podcasts app: a tap opens the server's page
/// (use it, check it, rename it, remove it); a swipe removes one, after asking. The selected
/// server — the one the library shows — has a checkmark.
struct ServersSection: View {
    @Environment(AppModel.self) private var model
    /// Owned by Settings, which shows the sheet: hung on this section, it closed at once.
    @Binding var isAdding: Bool
    /// Owned by Settings, where the question is asked: a dialog on a section of a form didn't
    /// show on iOS 26.5.
    @Binding var removing: ServerRecord?

    var body: some View {
        Section {
            ForEach(model.serversInOrder) { server in
                NavigationLink {
                    ServerDetailView(serverId: server.id)
                } label: {
                    HStack(spacing: Theme.Spacing.md) {
                        ServerKindIcon(kind: server.kind, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.displayName).foregroundStyle(.primary)
                            Text("\(server.kind.title) · \(server.auth.username)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .accessibilityIdentifier("servers.protocol.\(server.displayName)")
                        }
                        Spacer()
                        if server.id == model.activeServerId {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Selected")
                        }
                    }
                }
                .swipeActions {
                    Button("Remove", role: .destructive) { removing = server }
                }
                .accessibilityIdentifier("servers.row.\(server.displayName)")
            }
            Button { isAdding = true } label: { Label("Add a Server", systemImage: "plus") }
                .accessibilityIdentifier("servers.add")
        } header: {
            Text("Servers")
        } footer: {
            Text("The library shows the selected server. Music from any server can stay in the queue.")
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

import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// What the Recently Played widget shows: the app writes it into the App Group when the library
/// loads, a song changes or the app goes to the background; the widget only reads. Pictures
/// travel as small JPEGs, so the widget never needs the network or a sign-in. Copied from the
/// podcasts app's `WidgetSnapshot`.
struct WidgetSnapshot: Codable, Equatable {
    struct Entry: Codable, Equatable, Identifiable {
        enum Kind: String, Codable { case resume, album, playlist }
        /// The album or playlist as `TrackID` composes it (server and item); the song for `resume`.
        let id: String
        let kind: Kind
        let title: String
        /// The artist, or for `resume` the song's artist.
        let subtitle: String
        let cover: Data?

        var url: URL? {
            switch kind {
            case .resume: URL(string: "\(WidgetSnapshot.scheme)://resume")
            case .album, .playlist: WidgetSnapshot.playURL(kind: kind, id: id)
            }
        }
    }

    var entries: [Entry]
    var at: Date

    static let appGroup = "group.audio.own.musicplayer"
    static let scheme = "ownmusic"

    private static var file: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appendingPathComponent("recently-played.json")
    }

    static func load() -> WidgetSnapshot? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /// Writes the snapshot and asks the widgets to redraw; nothing happens when only the time changed.
    func save() {
        guard let file = Self.file, Self.load()?.entries != entries, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: file, options: .atomic)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// `ownmusic://play/album/<id>`; the id carries a `:`, so it is escaped whole.
    static func playURL(kind: Entry.Kind, id: String) -> URL? {
        guard let escaped = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: "\(scheme)://play/\(kind.rawValue)/\(escaped)")
    }

    /// What a link asks for, or nil for any other link.
    static func link(from url: URL) -> (kind: Entry.Kind, id: String?)? {
        guard url.scheme == scheme else { return nil }
        if url.host() == "resume" { return (.resume, nil) }
        guard url.host() == "play" else { return nil }
        let parts = url.absoluteString.dropFirst("\(scheme)://play/".count).split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let kind = Entry.Kind(rawValue: String(parts[0])), kind != .resume,
              let id = String(parts[1]).removingPercentEncoding else { return nil }
        return (kind, id)
    }
}

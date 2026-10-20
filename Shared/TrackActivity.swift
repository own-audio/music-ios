import ActivityKit
import AppIntents
import Foundation

/// The player's Live Activity: what the lock screen and the Dynamic Island show while music
/// plays. Copied from the podcasts app's `EpisodeActivity`; a song changes within one activity,
/// so the title is in the state, and the buttons are previous, play/pause and next.
struct TrackActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var trackId: String
        var title: String
        var artist: String
        var positionSecs: Double
        var durationSecs: Double
        var isPlaying: Bool
        /// When `positionSecs` was true, so the view can count on while playing.
        var at: Date
        /// A JPEG in the App Group container, by file name; the picture often arrives after
        /// the song has started.
        var coverFile: String?
        var hasNext: Bool
    }

    static let appGroup = "group.audio.own.musicplayer"

    static func coverURL(file: String?) -> URL? {
        guard let file else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appendingPathComponent(file)
    }
}

/// The Live Activity's buttons. iOS runs the intent in the app, where `handler` is set; the
/// widget extension only names the type.
struct PlaybackControlIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Control Playback"
    static let isDiscoverable = false

    enum Action: String, AppEnum {
        case toggle, previous, next
        static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Action")
        static let caseDisplayRepresentations: [Action: DisplayRepresentation] = [
            .toggle: "Play or Pause", .previous: "Previous Track", .next: "Next Track",
        ]
    }

    @Parameter(title: "Action")
    var action: Action

    init() {}
    init(_ action: Action) { self.action = action }

    /// Set by the app at launch; nil in the widget extension.
    nonisolated(unsafe) static var handler: (@MainActor (Action) async -> Void)?

    @MainActor
    func perform() async throws -> some IntentResult {
        await Self.handler?(action)
        return .result()
    }
}

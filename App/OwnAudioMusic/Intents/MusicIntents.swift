import AppIntents
import Foundation
import MusicLibrary

/// An album on the active server as Siri and Shortcuts see it, by its composite id (`TrackID`).
/// Shaped like the podcasts app's `ShowEntity`.
struct AlbumEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Album")
    static let defaultQuery = AlbumEntityQuery()

    let id: String
    let title: String
    let artist: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: artist.map { "\($0)" })
    }
}

/// Finds albums by what was said, with the server's search.
struct AlbumEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [AlbumEntity] {
        let model = await loadedModel()
        var out: [AlbumEntity] = []
        for id in identifiers {
            guard let (serverId, itemId) = TrackID.parse(id), serverId == model.activeServerId,
                  let album = try? await model.activeSource?.album(id: itemId).album else { continue }
            out.append(AlbumEntity(id: id, title: album.displayName, artist: album.artist))
        }
        return out
    }

    @MainActor
    func entities(matching string: String) async throws -> [AlbumEntity] {
        let model = await loadedModel()
        guard let serverId = model.activeServerId, let source = model.activeSource else { return [] }
        let albums = (try? await source.search(string).albums) ?? []
        return albums.prefix(10).map { AlbumEntity(id: TrackID.make(serverId: serverId, itemId: $0.id), title: $0.displayName, artist: $0.artist) }
    }

    @MainActor
    func suggestedEntities() async throws -> [AlbumEntity] {
        let model = await loadedModel()
        guard let serverId = model.activeServerId, let source = model.activeSource else { return [] }
        let albums = (try? await source.albums(.recentlyPlayed, limit: 10)) ?? []
        return albums.map { AlbumEntity(id: TrackID.make(serverId: serverId, itemId: $0.id), title: $0.displayName, artist: $0.artist) }
    }
}

/// A playlist on the active server.
struct PlaylistEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Playlist")
    static let defaultQuery = PlaylistEntityQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

/// Finds playlists by name among the active server's.
struct PlaylistEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [PlaylistEntity] {
        try await all().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [PlaylistEntity] {
        let needle = string.trimmingCharacters(in: .whitespaces)
        return try await all().filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    @MainActor
    func suggestedEntities() async throws -> [PlaylistEntity] {
        try await all()
    }

    @MainActor
    private func all() async throws -> [PlaylistEntity] {
        let model = await loadedModel()
        guard let serverId = model.activeServerId, let source = model.activeSource else { return [] }
        let playlists = (try? await source.playlists()) ?? []
        return playlists.map { PlaylistEntity(id: TrackID.make(serverId: serverId, itemId: $0.id), name: $0.name) }
    }
}

@MainActor
private func loadedModel() async -> AppModel {
    let model = AppModel.shared
    if !model.hasLoaded { await model.load() }
    return model
}

/// "Play Kind of Blue in own.music".
struct PlayAlbumIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play an Album"
    static let description = IntentDescription("Plays an album from your server.")

    @Parameter(title: "Album")
    var album: AlbumEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$album)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = await loadedModel()
        guard await model.playLink(kind: .album, id: album.id) else { throw IntentError.cantPlay }
        return .result()
    }
}

/// "Play Road Trip in own.music".
struct PlayPlaylistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play a Playlist"
    static let description = IntentDescription("Plays one of your playlists.")

    @Parameter(title: "Playlist")
    var playlist: PlaylistEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$playlist)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = await loadedModel()
        guard await model.playLink(kind: .playlist, id: playlist.id) else { throw IntentError.cantPlay }
        return .result()
    }
}

/// "Continue listening in own.music": what is in the player, else the queue from before.
struct ContinueListeningIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Continue Listening"
    static let description = IntentDescription("Goes on with the music you were listening to.")

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = await loadedModel()
        guard await model.continueListening() else { throw IntentError.nothingToPlay }
        return .result()
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case nothingToPlay, cantPlay

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .nothingToPlay: "There is nothing to continue; play something in own.music first."
        case .cantPlay: "That can't play right now."
        }
    }
}

/// The phrases Siri answers to without any setup in Shortcuts.
struct MusicShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ContinueListeningIntent(),
            phrases: [
                "Continue listening in \(.applicationName)",
                "Resume my music in \(.applicationName)",
            ],
            shortTitle: "Continue Listening",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: PlayPlaylistIntent(),
            phrases: [
                "Play \(\.$playlist) in \(.applicationName)",
                "Play my playlist \(\.$playlist) in \(.applicationName)",
            ],
            shortTitle: "Play a Playlist",
            systemImageName: "music.note.list"
        )
        AppShortcut(
            intent: PlayAlbumIntent(),
            phrases: [
                "Play the album \(\.$album) in \(.applicationName)",
                "Listen to \(\.$album) in \(.applicationName)",
            ],
            shortTitle: "Play an Album",
            systemImageName: "square.stack"
        )
    }
}

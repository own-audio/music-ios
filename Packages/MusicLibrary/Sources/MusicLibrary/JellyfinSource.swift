import Foundation
import JellyfinKit

/// A Jellyfin server.
public struct JellyfinSource: MusicSource {
    public let client: JellyfinClient

    public init(client: JellyfinClient) {
        self.client = client
    }

    public var capabilities: Capabilities { [.instantMix, .lowerBitrate, .libraryChoice, .countsPlaysFromReports] }

    /// No ratings in Jellyfin, so no "highest rated".
    public var albumSorts: [AlbumSort] {
        [.name, .artist, .newest, .recentlyPlayed, .mostPlayed, .random, .favorites]
    }

    public func checkConnection() async -> ConnectionStatus {
        switch await client.checkSession() {
        case .ok: .ok
        case .rejected: .rejected
        case .unreachable: .unreachable
        }
    }

    // MARK: - Browsing

    public func artists() async throws -> [Artist] {
        try await mapped { try await client.artists().map(Self.artist) }
    }

    public func albums(artistId: String) async throws -> [Album] {
        try await mapped { try await client.albums(artistId: artistId).map(Self.album) }
    }

    public func albums(_ sort: AlbumSort, limit: Int, offset: Int) async throws -> [Album] {
        let jellyfinSort: JellyfinKit.AlbumSort = switch sort {
        case .name: .name
        case .artist: .artist
        case .newest: .newest
        case .recentlyPlayed: .recentlyPlayed
        case .mostPlayed: .mostPlayed
        case .random: .random
        case .favorites: .favorites
        case .highestRated: throw SourceError.unsupported
        }
        return try await mapped { try await client.albums(jellyfinSort, limit: limit, offset: offset).map(Self.album) }
    }

    public func albums(genre: Genre, limit: Int) async throws -> [Album] {
        try await mapped { try await client.albums(genreId: genre.id, limit: limit).map(Self.album) }
    }

    public func album(id: String) async throws -> (album: Album, songs: [Song]) {
        try await mapped {
            let loaded = try await client.album(id: id)
            return (Self.album(loaded.album), loaded.songs.map(Self.song))
        }
    }

    public func song(id: String) async throws -> Song {
        try await mapped { Self.song(try await client.song(id: id)) }
    }

    public func songs(limit: Int, offset: Int) async throws -> [Song] {
        try await mapped { try await client.songs(limit: limit, offset: offset).map(Self.song) }
    }

    public func randomSongs(limit: Int, genre: Genre?) async throws -> [Song] {
        try await mapped { try await client.randomSongs(limit: limit, genreId: genre?.id).map(Self.song) }
    }

    public func genres() async throws -> [Genre] {
        try await mapped {
            try await client.genres().map { Genre(id: $0.id, name: $0.name, albumCount: $0.albumCount, songCount: $0.songCount) }
        }
    }

    public func search(_ text: String) async throws -> SearchResult {
        try await mapped {
            let found = try await client.search(text)
            return SearchResult(
                artists: found.artists.map(Self.artist), albums: found.albums.map(Self.album), songs: found.songs.map(Self.song)
            )
        }
    }

    public func instantMix(itemId: String) async throws -> [Song] {
        try await mapped { try await client.instantMix(itemId: itemId).map(Self.song) }
    }

    // MARK: - Favorites

    public func favorites() async throws -> FavoritesResult {
        try await mapped {
            let found = try await client.favorites()
            return FavoritesResult(
                artists: found.artists.map(Self.artist), albums: found.albums.map(Self.album), songs: found.songs.map(Self.song)
            )
        }
    }

    /// Jellyfin treats songs, albums and artists alike.
    public func setFavorite(_ kind: FavoriteKind, id: String, _ isFavorite: Bool) async throws {
        try await mapped { try await client.setFavorite(id, isFavorite) }
    }

    public func setRating(id: String, rating: Int) async throws {
        throw SourceError.unsupported
    }

    // MARK: - Playlists

    public func playlists() async throws -> [Playlist] {
        try await mapped { try await client.playlists().map(Self.playlist) }
    }

    public func playlist(id: String) async throws -> (playlist: Playlist, songs: [Song]) {
        try await mapped {
            let loaded = try await client.playlist(id: id)
            return (Self.playlist(loaded.playlist), loaded.songs.map(Self.song))
        }
    }

    public func createPlaylist(name: String, songIds: [String]) async throws {
        try await mapped { _ = try await client.createPlaylist(name: name, songIds: songIds) }
    }

    public func addToPlaylist(id: String, songIds: [String]) async throws {
        try await mapped { try await client.addToPlaylist(id: id, songIds: songIds) }
    }

    /// By each entry's own id; entries without one can't be removed.
    public func removeFromPlaylist(id: String, entries: [PlaylistEntry]) async throws {
        let entryIds = entries.compactMap(\.entryId)
        guard !entryIds.isEmpty else { return }
        try await mapped { try await client.removeFromPlaylist(id: id, entryIds: entryIds) }
    }

    public func renamePlaylist(id: String, to name: String) async throws {
        try await mapped { try await client.renamePlaylist(id: id, to: name) }
    }

    public func deletePlaylist(id: String) async throws {
        try await mapped { try await client.deletePlaylist(id: id) }
    }

    // MARK: - Lyrics

    public func lyrics(for song: Song) async throws -> [Lyrics] {
        try await mapped {
            guard let found = try await client.lyrics(songId: song.id) else { return [] }
            return [Lyrics(lines: found.lines.map { Lyrics.Line(startMs: $0.startMs, text: $0.text) }, isSynced: found.isSynced)]
        }
    }

    // MARK: - Playback reporting

    public func reportNowPlaying(songId: String, positionSecs: Double) async throws {
        try await mapped { try await client.reportStart(songId: songId, positionSecs: positionSecs) }
    }

    public func reportProgress(songId: String, positionSecs: Double, isPaused: Bool) async throws {
        try await mapped { try await client.reportProgress(songId: songId, positionSecs: positionSecs, isPaused: isPaused) }
    }

    public func reportStopped(songId: String, positionSecs: Double) async throws {
        try await mapped { try await client.reportStopped(songId: songId, positionSecs: positionSecs) }
    }

    public func reportPlayed(songId: String, at date: Date) async throws {
        try await mapped { try await client.markPlayed(songId: songId, at: date) }
    }

    // MARK: - URLs

    public func streamURL(songId: String, maxBitrate: Int?) -> URL {
        client.streamURL(songId: songId, maxBitrate: maxBitrate)
    }

    public func downloadURL(songId: String) -> URL {
        client.streamURL(songId: songId)
    }

    public func coverURL(id: String, size: Int) -> URL {
        client.imageURL(itemId: id, size: size)
    }

    public func musicLibraries() async throws -> [MusicLibraryInfo] {
        try await mapped { try await client.musicLibraries().map { MusicLibraryInfo(id: $0.id, name: $0.name) } }
    }

    public func signOut() async {
        await client.signOut()
    }

    // MARK: - Mapping

    static func artist(_ artist: JellyfinKit.Artist) -> Artist {
        Artist(id: artist.id, name: artist.name, albumCount: artist.albumCount, coverArt: artist.imageId, isFavorite: artist.isFavorite)
    }

    static func album(_ album: JellyfinKit.Album) -> Album {
        Album(
            id: album.id, name: album.name, artist: album.artist, artistId: album.artistId,
            songCount: album.songCount, duration: album.duration, coverArt: album.coverArt, year: album.year,
            genre: album.genre, isFavorite: album.isFavorite, playCount: album.playCount, dateAdded: album.dateAdded
        )
    }

    static func song(_ song: JellyfinKit.Song) -> Song {
        Song(
            id: song.id, title: song.title, album: song.album, artist: song.artist, albumId: song.albumId,
            artistId: song.artistId, track: song.track, discNumber: song.discNumber, duration: song.duration,
            genre: song.genre, coverArt: song.coverArt, suffix: song.suffix, bitRate: song.bitRate,
            isFavorite: song.isFavorite, playCount: song.playCount,
            // Jellyfin measures loudness per track; there is no album value or peak.
            gain: song.normalizationGain.map { Gain(track: $0) },
            playlistEntryId: song.playlistItemId
        )
    }

    static func playlist(_ playlist: JellyfinKit.Playlist) -> Playlist {
        Playlist(id: playlist.id, name: playlist.name, songCount: playlist.songCount, duration: playlist.duration, coverArt: playlist.coverArt)
    }

    private func mapped<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as JellyfinClient.JellyfinError {
            throw Self.sourceError(error)
        }
    }

    static func sourceError(_ error: JellyfinClient.JellyfinError) -> SourceError {
        switch error {
        case .unauthorized: .signInRejected
        case .forbidden: .notAllowed
        case .notFound: .notFound
        case .http(let code): .http(code)
        case .decoding: .unreadable
        case .network: .network
        case .offline: .offline
        }
    }
}

import Foundation
import SubsonicKit

/// A Subsonic or OpenSubsonic server (Navidrome, Gonic, Airsonic, LMS, Ampache, own.audio…).
public struct SubsonicSource: MusicSource {
    public let client: SubsonicClient
    private let extensions = ExtensionCache()

    public init(client: SubsonicClient) {
        self.client = client
    }

    /// Navidrome, Gonic, Airsonic and own.audio transcode on request; a server that doesn't
    /// ignores the parameters and sends the original, so asking is always safe.
    public var capabilities: Capabilities { [.ratings, .lowerBitrate] }

    public var albumSorts: [AlbumSort] {
        [.name, .artist, .newest, .recentlyPlayed, .mostPlayed, .random, .favorites, .highestRated]
    }

    public func checkConnection() async -> ConnectionStatus {
        switch await client.checkConnection() {
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
        try await mapped { try await client.artist(id: artistId).albums.map(Self.album) }
    }

    public func albums(_ sort: AlbumSort, limit: Int, offset: Int) async throws -> [Album] {
        let type: AlbumListType = switch sort {
        case .name: .alphabeticalByName
        case .artist: .alphabeticalByArtist
        case .newest: .newest
        case .recentlyPlayed: .recent
        case .mostPlayed: .frequent
        case .random: .random
        case .favorites: .starred
        case .highestRated: .highest
        }
        return try await mapped { try await client.albumList(type, size: limit, offset: offset).map(Self.album) }
    }

    public func albums(genre: Genre, limit: Int) async throws -> [Album] {
        try await mapped { try await client.albums(genre: genre.id, size: limit).map(Self.album) }
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
        try await mapped { try await client.songs(size: limit, offset: offset).map(Self.song) }
    }

    public func randomSongs(limit: Int, genre: Genre?) async throws -> [Song] {
        try await mapped { try await client.randomSongs(size: limit, genre: genre?.id).map(Self.song) }
    }

    public func genres() async throws -> [Genre] {
        try await mapped {
            try await client.genres().map { Genre(id: $0.value, name: $0.value, albumCount: $0.albumCount, songCount: $0.songCount) }
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
        throw SourceError.unsupported
    }

    // MARK: - Favorites and ratings

    public func favorites() async throws -> FavoritesResult {
        try await mapped {
            let starred = try await client.starred()
            return FavoritesResult(
                artists: starred.artists.map(Self.artist), albums: starred.albums.map(Self.album), songs: starred.songs.map(Self.song)
            )
        }
    }

    public func setFavorite(_ kind: FavoriteKind, id: String, _ isFavorite: Bool) async throws {
        try await mapped {
            let ids = [id]
            switch (kind, isFavorite) {
            case (.song, true): try await client.star(songIds: ids)
            case (.song, false): try await client.unstar(songIds: ids)
            case (.album, true): try await client.star(albumIds: ids)
            case (.album, false): try await client.unstar(albumIds: ids)
            case (.artist, true): try await client.star(artistIds: ids)
            case (.artist, false): try await client.unstar(artistIds: ids)
            }
        }
    }

    public func setRating(id: String, rating: Int) async throws {
        try await mapped { try await client.setRating(id: id, rating: rating) }
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
        try await mapped { try await client.updatePlaylist(id: id, songIdsToAdd: songIds) }
    }

    /// By position; the server shifts the rest, so callers reload afterwards.
    public func removeFromPlaylist(id: String, entries: [PlaylistEntry]) async throws {
        try await mapped { try await client.updatePlaylist(id: id, songIndicesToRemove: entries.map(\.index)) }
    }

    public func renamePlaylist(id: String, to name: String) async throws {
        try await mapped { try await client.updatePlaylist(id: id, name: name) }
    }

    public func deletePlaylist(id: String) async throws {
        try await mapped { try await client.deletePlaylist(id: id) }
    }

    // MARK: - Lyrics

    public func lyrics(for song: Song) async throws -> [Lyrics] {
        let useExtension = await extensions.contains("songLyrics", from: client)
        return try await mapped {
            let asked = SubsonicKit.Song(id: song.id, title: song.title, album: song.album, artist: song.artist)
            return try await client.lyrics(for: asked, useSongLyricsExtension: useExtension).map {
                Lyrics(
                    lines: $0.lines.map { Lyrics.Line(startMs: $0.startMs, text: $0.text) },
                    isSynced: $0.isSynced, language: $0.language, offsetMs: $0.offsetMs
                )
            }
        }
    }

    // MARK: - Playback reporting

    public func reportNowPlaying(songId: String, positionSecs: Double) async throws {
        try await mapped { try await client.scrobble(songId: songId, submission: false) }
    }

    /// Subsonic has no progress or stop reports.
    public func reportProgress(songId: String, positionSecs: Double, isPaused: Bool) async throws {}

    public func reportStopped(songId: String, positionSecs: Double) async throws {}

    public func reportPlayed(songId: String, at date: Date) async throws {
        try await mapped { try await client.scrobble(songId: songId, submission: true, time: date) }
    }

    // MARK: - URLs

    public func streamURL(songId: String, maxBitrate: Int?) -> URL {
        client.streamURL(songId: songId, maxBitRate: maxBitrate.map { $0 / 1000 })
    }

    public func downloadURL(songId: String) -> URL {
        client.streamURL(songId: songId)
    }

    public func coverURL(id: String, size: Int) -> URL {
        client.coverURL(id: id, size: size)
    }

    public func musicLibraries() async throws -> [MusicLibraryInfo] { [] }

    public func signOut() async {}

    // MARK: - Mapping

    static func artist(_ artist: SubsonicKit.Artist) -> Artist {
        Artist(
            id: artist.id, name: artist.name, albumCount: artist.albumCount,
            imageURL: artist.artistImageUrl.flatMap(URL.init(string:)), isFavorite: artist.starred != nil
        )
    }

    static func album(_ album: SubsonicKit.Album) -> Album {
        Album(
            id: album.id, name: album.name, artist: album.artist, artistId: album.artistId,
            songCount: album.songCount, duration: album.duration, coverArt: album.coverArt ?? album.id,
            year: album.year, isFavorite: album.starred != nil, rating: album.userRating, playCount: album.playCount
        )
    }

    static func song(_ song: SubsonicKit.Song) -> Song {
        Song(
            id: song.id, title: song.title, album: song.album, artist: song.artist,
            albumId: song.albumId, artistId: song.artistId, track: song.track, discNumber: song.discNumber,
            duration: song.duration, genre: song.genre,
            // Some servers give songs no cover id of their own; the album's is the right fallback.
            coverArt: song.coverArt ?? song.albumId, suffix: song.suffix, bitRate: song.bitRate,
            isFavorite: song.starred != nil, rating: song.userRating, playCount: song.playCount,
            gain: song.replayGain.flatMap {
                $0.isEmpty ? nil : Gain(track: $0.trackGain, album: $0.albumGain, trackPeak: $0.trackPeak, albumPeak: $0.albumPeak)
            }
        )
    }

    static func playlist(_ playlist: SubsonicKit.Playlist) -> Playlist {
        Playlist(
            id: playlist.id, name: playlist.name, comment: playlist.comment, owner: playlist.owner,
            songCount: playlist.songCount, duration: playlist.duration, coverArt: playlist.coverArt
        )
    }

    private func mapped<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as SubsonicClient.SubsonicError {
            throw Self.sourceError(error)
        }
    }

    static func sourceError(_ error: SubsonicClient.SubsonicError) -> SourceError {
        switch error {
        case .wrongCredentials: .signInRejected
        case .notAuthorized: .notAllowed
        case .http(let code): .http(code)
        case .server(_, let message): message.isEmpty ? .http(200) : .server(message)
        case .decoding: .unreadable
        case .network: .network
        case .offline: .offline
        }
    }
}

/// OpenSubsonic extensions, asked for once per source.
actor ExtensionCache {
    private var names: Set<String>?

    func contains(_ name: String, from client: SubsonicClient) async -> Bool {
        if names == nil { names = await client.openSubsonicExtensions() }
        return names?.contains(name) ?? false
    }
}

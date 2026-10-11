import Foundation
import OwnAudioKit

/// A source that can keep the library on the phone up to date from a change feed: the whole
/// library once, then only what changed. Sources without one are synced by paging.
public protocol ChangeFeedCatalogue: MusicSource {
    /// Brings `state` up to date — from scratch when it is nil, or when the server says the
    /// changes since it are too many or too old — and returns it with the library it describes.
    func syncCatalogue(_ state: FeedState?) async throws -> FeedResult
}

/// Where a change feed was read up to, and the records it brought, kept between launches.
public struct FeedState: Codable, Sendable {
    let cursor: String
    /// By kind (`track`, `album`, `contributor`, `genre`, `favourite.track`, …), then by id.
    var records: [String: [String: JSONValue]]
}

public struct FeedResult: Sendable {
    public let state: FeedState
    public let artists: [Artist]
    public let albums: [Album]
    public let songs: [Song]
}

/// An own.audio server from 1.0.0-beta.7. The library on the phone comes from its own API's
/// snapshot and change feed (`/api/v2`); everything else still goes through its Subsonic API —
/// playlists, search, random songs, lyrics and play-count orders are not in the new API yet —
/// and both use the same ids, so the two never disagree about what is what.
public struct OwnAudioSource: MusicSource, ChangeFeedCatalogue {
    public let subsonic: SubsonicSource
    public let client: OwnAudioClient

    public init(subsonic: SubsonicSource, client: OwnAudioClient) {
        self.subsonic = subsonic
        self.client = client
    }

    public var capabilities: Capabilities { subsonic.capabilities }
    public var albumSorts: [AlbumSort] { subsonic.albumSorts }
    public func checkConnection() async -> ConnectionStatus { await subsonic.checkConnection() }

    public func artists() async throws -> [Artist] { try await subsonic.artists() }
    public func albums(artistId: String) async throws -> [Album] { try await subsonic.albums(artistId: artistId) }
    public func albums(_ sort: AlbumSort, limit: Int, offset: Int) async throws -> [Album] { try await subsonic.albums(sort, limit: limit, offset: offset) }
    public func albums(genre: Genre, limit: Int) async throws -> [Album] { try await subsonic.albums(genre: genre, limit: limit) }
    public func album(id: String) async throws -> (album: Album, songs: [Song]) { try await subsonic.album(id: id) }
    public func song(id: String) async throws -> Song { try await subsonic.song(id: id) }
    public func songs(limit: Int, offset: Int) async throws -> [Song] { try await subsonic.songs(limit: limit, offset: offset) }
    public func randomSongs(limit: Int, genre: Genre?) async throws -> [Song] { try await subsonic.randomSongs(limit: limit, genre: genre) }
    public func genres() async throws -> [Genre] { try await subsonic.genres() }
    public func search(_ text: String) async throws -> SearchResult { try await subsonic.search(text) }
    public func instantMix(itemId: String) async throws -> [Song] { try await subsonic.instantMix(itemId: itemId) }

    public func favorites() async throws -> FavoritesResult { try await subsonic.favorites() }
    public func setFavorite(_ kind: FavoriteKind, id: String, _ isFavorite: Bool) async throws { try await subsonic.setFavorite(kind, id: id, isFavorite) }
    public func setRating(id: String, rating: Int) async throws { try await subsonic.setRating(id: id, rating: rating) }

    public func playlists() async throws -> [Playlist] { try await subsonic.playlists() }
    public func playlist(id: String) async throws -> (playlist: Playlist, songs: [Song]) { try await subsonic.playlist(id: id) }
    public func createPlaylist(name: String, songIds: [String]) async throws { try await subsonic.createPlaylist(name: name, songIds: songIds) }
    public func addToPlaylist(id: String, songIds: [String]) async throws { try await subsonic.addToPlaylist(id: id, songIds: songIds) }
    public func removeFromPlaylist(id: String, entries: [PlaylistEntry]) async throws { try await subsonic.removeFromPlaylist(id: id, entries: entries) }
    public func renamePlaylist(id: String, to name: String) async throws { try await subsonic.renamePlaylist(id: id, to: name) }
    public func deletePlaylist(id: String) async throws { try await subsonic.deletePlaylist(id: id) }

    public func lyrics(for song: Song) async throws -> [Lyrics] { try await subsonic.lyrics(for: song) }

    public func reportNowPlaying(songId: String, positionSecs: Double) async throws { try await subsonic.reportNowPlaying(songId: songId, positionSecs: positionSecs) }
    public func reportProgress(songId: String, positionSecs: Double, isPaused: Bool) async throws { try await subsonic.reportProgress(songId: songId, positionSecs: positionSecs, isPaused: isPaused) }
    public func reportStopped(songId: String, positionSecs: Double) async throws { try await subsonic.reportStopped(songId: songId, positionSecs: positionSecs) }
    public func reportPlayed(songId: String, at date: Date) async throws { try await subsonic.reportPlayed(songId: songId, at: date) }

    public func streamURL(songId: String, maxBitrate: Int?) -> URL { subsonic.streamURL(songId: songId, maxBitrate: maxBitrate) }
    public func downloadURL(songId: String) -> URL { subsonic.downloadURL(songId: songId) }
    public func coverURL(id: String, size: Int) -> URL { subsonic.coverURL(id: id, size: size) }

    public func musicLibraries() async throws -> [MusicLibraryInfo] { try await subsonic.musicLibraries() }

    /// Ends both: the API's session (its refresh token) and the Subsonic one.
    public func signOut() async {
        await client.signOut()
        await subsonic.signOut()
    }

    // MARK: - The library on the phone

    /// What the snapshot holds for the music library.
    static let snapshotKinds = ["contributor", "album", "genre", "track", "favourite", "rating"]

    /// Records of these kinds are kept; the feed's others (books, podcasts, progress…) are not
    /// this app's.
    static func keeps(_ kind: String) -> Bool {
        ["contributor", "album", "genre", "track"].contains(kind)
            || kind.hasPrefix("favourite.") || kind.hasPrefix("rating.")
    }

    public func syncCatalogue(_ state: FeedState?) async throws -> FeedResult {
        guard await client.tokens.current != nil else { throw SourceError.unsupported }
        do {
            let updated: FeedState
            if let state, let changed = try await changes(since: state) {
                updated = changed
            } else {
                updated = try await snapshot()
            }
            let (artists, albums, songs) = Self.library(updated)
            return FeedResult(state: updated, artists: artists, albums: albums, songs: songs)
        } catch let error as OwnAudioError {
            throw Self.sourceError(error)
        }
    }

    /// The state with the changes applied, or nil when a fresh snapshot is needed.
    private func changes(since state: FeedState) async throws -> FeedState? {
        var state = state
        var cursor = state.cursor
        while true {
            let page: ChangesAnswer
            do {
                page = try await client.changes(since: cursor)
            } catch OwnAudioError.problem(let p) where p.code == "sync_cursor_expired" || p.code == "invalid_cursor" {
                return nil
            }
            if page.reset { return nil }
            for change in page.changes where Self.keeps(change.kind) {
                if change.op == "upsert", let record = change.record {
                    state.records[change.kind, default: [:]][change.id] = record
                } else {
                    state.records[change.kind]?[change.id] = nil
                }
            }
            cursor = page.cursor
            if !page.hasMore { break }
        }
        return FeedState(cursor: cursor, records: state.records)
    }

    private func snapshot() async throws -> FeedState {
        var records: [String: [String: JSONValue]] = [:]
        var begin: String?
        var end: String?
        try await client.snapshot(kinds: Self.snapshotKinds) { line in
            switch line {
            case .begin(let cursor): begin = cursor
            case .record(let kind, let id, let record):
                if Self.keeps(kind) { records[kind, default: [:]][id] = record }
            case .end(let cursor): end = cursor
            }
        }
        guard let cursor = end ?? begin else { throw SourceError.unreadable }
        return FeedState(cursor: cursor, records: records)
    }

    // MARK: - From the API's records to the app's

    static func library(_ state: FeedState) -> (artists: [Artist], albums: [Album], songs: [Song]) {
        func decoded<T: Decodable>(_ kind: String, _ type: T.Type) -> [String: T] {
            var out: [String: T] = [:]
            for (id, record) in state.records[kind] ?? [:] {
                if let value = try? JSONDecoder.ownAudio.decode(T.self, from: JSONEncoder().encode(record)) {
                    out[id] = value
                }
            }
            return out
        }
        let contributors = decoded("contributor", OwnAudioKit.Contributor.self)
        let albums = decoded("album", OwnAudioKit.Album.self)
        let genres = decoded("genre", OwnAudioKit.Genre.self)
        let tracks = decoded("track", OwnAudioKit.Track.self)
        func ids(_ kind: String) -> Set<String> { Set((state.records[kind] ?? [:]).keys) }
        func ratings(_ kind: String) -> [String: Int] {
            decoded(kind, OwnAudioKit.Rating.self).mapValues(\.rating)
        }
        let favouriteTracks = ids("favourite.track"), favouriteAlbums = ids("favourite.album"), favouriteArtists = ids("favourite.contributor")
        let trackRatings = ratings("rating.track"), albumRatings = ratings("rating.album")

        /// The credit line as printed: names in order with what joins them.
        func line(_ credits: [Credit], roles: Set<String>) -> String? {
            let parts = credits.filter { roles.contains($0.role) }
            guard !parts.isEmpty else { return nil }
            return parts.map { (contributors[$0.contributorId]?.name ?? "") + $0.joinPhrase }.joined()
        }
        func firstArtist(_ credits: [Credit]) -> String? {
            credits.first { $0.role == "artist" }?.contributorId
        }

        let songs: [Song] = tracks.values.map { t in
            let album = t.albumId.flatMap { albums[$0] }
            let seconds = t.durationMs.map { Int($0 / 1000) }
            return Song(
                id: t.id, title: t.title, album: album?.title, artist: line(t.credits, roles: ["artist", "featured"]),
                albumId: t.albumId, artistId: firstArtist(t.credits), track: t.trackNumber, discNumber: t.discNumber,
                duration: seconds, genre: t.genreIds.first.flatMap { genres[$0]?.name },
                coverArt: t.image != nil ? t.id : (album?.image != nil ? t.albumId : nil),
                suffix: suffix(t.contentType),
                bitRate: (t.sizeBytes ?? 0) > 0 && (seconds ?? 0) > 0 ? Int((t.sizeBytes ?? 0) * 8 / Int64(seconds ?? 1)) : nil,
                isFavorite: favouriteTracks.contains(t.id), rating: trackRatings[t.id]
            )
        }
        let albumList: [Album] = albums.values.map { a in
            Album(
                id: a.id, name: a.title, artist: line(a.credits, roles: ["artist"]), artistId: firstArtist(a.credits),
                songCount: a.trackCount, duration: Int(a.durationMs / 1000), coverArt: a.image != nil ? a.id : nil,
                year: a.releaseDate.flatMap { Int($0.prefix(4)) }, isFavorite: favouriteAlbums.contains(a.id),
                rating: albumRatings[a.id], dateAdded: a.createdAt
            )
        }
        // Artists are the contributors credited as one; authors, narrators and hosts are the
        // same records but not this app's.
        var albumCounts: [String: Int] = [:]
        for a in albums.values {
            for c in Set(a.credits.filter { $0.role == "artist" }.map(\.contributorId)) { albumCounts[c, default: 0] += 1 }
        }
        let trackArtists = Set(tracks.values.flatMap { $0.credits.filter { $0.role == "artist" }.map(\.contributorId) })
        let artists: [Artist] = contributors.values
            .filter { albumCounts[$0.id] != nil || trackArtists.contains($0.id) }
            .map { c in
                Artist(
                    id: c.id, name: c.name, albumCount: albumCounts[c.id] ?? 0,
                    imageURL: c.image.flatMap { URL(string: $0 + "&w=512") }, isFavorite: favouriteArtists.contains(c.id)
                )
            }
        return (artists, albumList, songs)
    }

    /// The format from the content type, as Subsonic names it.
    static func suffix(_ contentType: String?) -> String? {
        switch contentType?.lowercased() {
        case "audio/mpeg", "audio/mp3": "mp3"
        case "audio/flac", "audio/x-flac": "flac"
        case "audio/mp4", "audio/x-m4a", "audio/m4a": "m4a"
        case "audio/aac": "aac"
        case "audio/ogg", "audio/vorbis": "ogg"
        case "audio/opus": "opus"
        case "audio/wav", "audio/x-wav", "audio/wave": "wav"
        default: nil
        }
    }

    static func sourceError(_ error: OwnAudioError) -> SourceError {
        switch error {
        case .signedOut, .twoFactorRequired: .signInRejected
        case .problem(let p) where p.status == 401: .signInRejected
        case .problem(let p) where p.status == 403: .notAllowed
        case .problem(let p) where p.status == 404: .notFound
        case .problem(let p): .server(p.detail ?? p.code)
        case .http(let code): .http(code)
        case .decoding: .unreadable
        case .network: .network
        }
    }
}

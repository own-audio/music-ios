import Foundation
import OwnAudioKit

/// A source that can keep the library on the phone up to date from a change feed: the whole
/// library once, then only what changed. Sources without one are synced by paging.
public protocol ChangeFeedCatalogue: MusicSource {
    /// Brings `state` up to date — from scratch when it is nil, or when the server says the
    /// changes since it are too many or too old — and returns it with the library it describes.
    func syncCatalogue(_ state: FeedState?) async throws -> FeedResult
}

/// A change made while offline, kept on the phone and sent later.
public struct OfflineEdit: Sendable, Equatable {
    public enum Change: Sendable, Equatable {
        case favorite(FavoriteKind, Bool)
        /// A song or an album; 0 takes the rating away.
        case rating(FavoriteKind, Int)
        /// A song heard for `heardSecs`, counted when that much had been heard.
        case played(startedAt: Date, heardSecs: Double)
    }

    /// The phone's own id for it, which makes sending it twice harmless.
    public let clientId: String
    public let itemId: String
    public let change: Change
    public let madeAt: Date

    public init(clientId: String, itemId: String, change: Change, madeAt: Date) {
        self.clientId = clientId
        self.itemId = itemId
        self.change = change
        self.madeAt = madeAt
    }
}

/// A source that takes what was changed offline in one request, rather than one call each.
public protocol BatchedOfflineEdits: MusicSource {
    /// Sends `edits`, in the order made. Returns normally once the server has answered every
    /// one — including those it refused for good (the song is gone), which are not worth
    /// sending again. Throws when nothing was answered; `SourceError.unsupported` means this
    /// server has to be sent them one at a time.
    func push(_ edits: [OfflineEdit]) async throws
}

/// A source that says when the library changed elsewhere, so the copy on the phone can catch
/// up at once rather than at the next scheduled sync.
public protocol LiveLibraryUpdates: MusicSource {
    /// One element per change, until the connection ends (normally or with an error).
    func libraryChanges() -> AsyncThrowingStream<Void, Error>
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

/// An own.audio server from 1.0.0-beta.7, through its own API (`/api/v2`): the library on the
/// phone from its snapshot and change feed, and — from 1.0.0-beta.11 — playlists, search,
/// random songs, lyrics and the recently / most played orders. Browsing, streaming and covers
/// still go through its Subsonic API, which uses the same ids, so the two never disagree about
/// what is what. Offline, or when the API's sign-in was refused, everything goes through
/// Subsonic, whose saved answers keep the screens working.
public struct OwnAudioSource: MusicSource, ChangeFeedCatalogue, BatchedOfflineEdits, LiveLibraryUpdates {
    public let subsonic: SubsonicSource
    public let client: OwnAudioClient
    let listener: ListenerState
    let offline: OfflineSwitch?

    public init(subsonic: SubsonicSource, client: OwnAudioClient, listener: ListenerState = ListenerState(), offline: OfflineSwitch? = nil) {
        self.subsonic = subsonic
        self.client = client
        self.listener = listener
        self.offline = offline
    }

    /// Instant mix is left out: the server has nothing to pick similar songs from (its Subsonic
    /// answer is always empty), so the action would only ever do nothing.
    public var capabilities: Capabilities { subsonic.capabilities.subtracting(.instantMix) }
    public var albumSorts: [AlbumSort] { subsonic.albumSorts }
    /// Both sign-ins: the API's tokens (gone after a refused refresh) and the Subsonic key.
    public func checkConnection() async -> ConnectionStatus {
        guard await client.tokens.current != nil else { return .rejected }
        do {
            _ = try await client.me()
        } catch OwnAudioError.signedOut {
            return .rejected
        } catch OwnAudioError.problem(let p) where p.status == 401 {
            return .rejected
        } catch {
            return .unreachable
        }
        return await subsonic.checkConnection()
    }

    public func artists() async throws -> [Artist] { try await subsonic.artists() }
    public func albums(artistId: String) async throws -> [Album] { try await subsonic.albums(artistId: artistId) }
    public func albums(_ sort: AlbumSort, limit: Int, offset: Int) async throws -> [Album] {
        guard sort == .recentlyPlayed || sort == .mostPlayed else { return try await subsonic.albums(sort, limit: limit, offset: offset) }
        return try await throughAPI {
            let played = try await client.played(.album, order: sort == .mostPlayed ? "most" : "recent", limit: min(offset + limit, 500)).items
            let wanted = Array(played.dropFirst(offset).prefix(limit))
            let records = try await withThrowingTaskGroup(of: (String, WithIncluded<OwnAudioKit.Album>?).self) { group in
                for item in wanted {
                    group.addTask { (item.id, try? await client.album(id: item.id, include: ["contributors"])) }
                }
                return try await group.reduce(into: [String: WithIncluded<OwnAudioKit.Album>]()) { $0[$1.0] = $1.1 }
            }
            let listener = listener.current
            return wanted.compactMap { item in
                records[item.id].map { RecordMapper($0.included, listener: listener).album($0.record, playCount: item.playCount) }
            }
        } else: {
            try await subsonic.albums(sort, limit: limit, offset: offset)
        }
    }
    public func albums(genre: Genre, limit: Int) async throws -> [Album] { try await subsonic.albums(genre: genre, limit: limit) }
    public func album(id: String) async throws -> (album: Album, songs: [Song]) { try await subsonic.album(id: id) }
    public func song(id: String) async throws -> Song { try await subsonic.song(id: id) }
    public func songs(limit: Int, offset: Int) async throws -> [Song] { try await subsonic.songs(limit: limit, offset: offset) }
    public func randomSongs(limit: Int, genre: Genre?) async throws -> [Song] {
        try await throughAPI {
            // The app's genres come from the Subsonic API, by name; the API wants its id.
            var genreId: String?
            if let genre {
                let all = try await client.all { try await client.genres(cursor: $0) }
                guard let match = all.first(where: { $0.name.caseInsensitiveCompare(genre.name) == .orderedSame }) else { return [] }
                genreId = match.id
            }
            let page = try await client.randomTracks(genreId: genreId, limit: min(max(limit, 1), 500), include: Self.trackIncludes)
            let mapper = RecordMapper(page.included, listener: listener.current)
            return page.items.map { mapper.song($0) }
        } else: {
            try await subsonic.randomSongs(limit: limit, genre: genre)
        }
    }
    public func genres() async throws -> [Genre] { try await subsonic.genres() }
    public func search(_ text: String) async throws -> SearchResult {
        try await throughAPI {
            let answer = try await client.search(text, limit: 20, include: Self.trackIncludes)
            var mapper = RecordMapper(answer.included, listener: listener.current)
            for artist in answer.artists { mapper.contributors[artist.id] = artist }
            // An album found by its title brings no names with it: fetch those not met yet.
            let missing = Set(answer.albums.flatMap { $0.credits.map(\.contributorId) }).subtracting(mapper.contributors.keys)
            for contributor in await contributors(Array(missing)) { mapper.contributors[contributor.id] = contributor }
            return SearchResult(
                artists: answer.artists.map { mapper.artist($0) },
                albums: answer.albums.map { mapper.album($0) },
                songs: answer.tracks.map { mapper.song($0) }
            )
        } else: {
            try await subsonic.search(text)
        }
    }
    public func instantMix(itemId: String) async throws -> [Song] { try await subsonic.instantMix(itemId: itemId) }

    public func favorites() async throws -> FavoritesResult { try await subsonic.favorites() }
    public func setFavorite(_ kind: FavoriteKind, id: String, _ isFavorite: Bool) async throws {
        try await subsonic.setFavorite(kind, id: id, isFavorite)
        listener.setFavourite(id, isFavorite)
    }

    public func setRating(id: String, rating: Int) async throws {
        try await subsonic.setRating(id: id, rating: rating)
        listener.setRating(id, rating)
    }

    public func playlists() async throws -> [Playlist] {
        try await throughAPI {
            let mine = try await userId()
            return try await client.all { try await client.playlists(cursor: $0) }.map { playlist($0, mine: mine) }
        } else: {
            try await subsonic.playlists()
        }
    }

    public func playlist(id: String) async throws -> (playlist: Playlist, songs: [Song]) {
        try await throughAPI {
            async let record = client.playlist(id: id)
            async let mine = userId()
            var songs: [Song] = []
            var cursor: String?
            let listener = listener.current
            repeat {
                let page = try await client.playlistEntries(id: id, include: Self.trackIncludes, cursor: cursor)
                let mapper = RecordMapper(page.included, listener: listener)
                songs += page.items.map { mapper.song($0.track, entryId: $0.id) }
                cursor = page.next
            } while cursor != nil
            return (playlist(try await record, mine: try await mine), songs)
        } else: {
            try await subsonic.playlist(id: id)
        }
    }

    public func createPlaylist(name: String, songIds: [String]) async throws {
        try await throughAPI { _ = try await client.createPlaylist(name: name, trackIds: songIds) } else: {
            try await subsonic.createPlaylist(name: name, songIds: songIds)
        }
    }

    public func addToPlaylist(id: String, songIds: [String]) async throws {
        try await throughAPI { _ = try await client.addToPlaylist(id: id, trackIds: songIds) } else: {
            try await subsonic.addToPlaylist(id: id, songIds: songIds)
        }
    }

    /// By the entries' own ids, which only songs listed through the API carry; a list from the
    /// Subsonic API (saved offline) goes back that way, by position.
    public func removeFromPlaylist(id: String, entries: [PlaylistEntry]) async throws {
        let entryIds = entries.compactMap(\.entryId)
        guard entryIds.count == entries.count else { return try await subsonic.removeFromPlaylist(id: id, entries: entries) }
        try await throughAPI {
            for entryId in entryIds { try await client.removeFromPlaylist(id: id, entryId: entryId) }
        } else: {
            try await subsonic.removeFromPlaylist(id: id, entries: entries)
        }
    }

    public func renamePlaylist(id: String, to name: String) async throws {
        try await throughAPI { _ = try await client.renamePlaylist(id: id, to: name) } else: {
            try await subsonic.renamePlaylist(id: id, to: name)
        }
    }

    public func deletePlaylist(id: String) async throws {
        try await throughAPI { try await client.deletePlaylist(id: id) } else: {
            try await subsonic.deletePlaylist(id: id)
        }
    }

    public func lyrics(for song: Song) async throws -> [Lyrics] {
        try await throughAPI {
            let answer = try await client.lyrics(trackId: song.id)
            guard answer.text != nil, !answer.lines.isEmpty else { return [] }
            return [Lyrics(lines: answer.lines.map { Lyrics.Line(startMs: $0.startMs, text: $0.text) }, isSynced: answer.synced)]
        } else: {
            try await subsonic.lyrics(for: song)
        }
    }

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

    // MARK: - Through the API, or Subsonic

    /// What a track answer brings with it, so songs have their album, artists and genre names.
    static let trackIncludes = ["albums", "contributors", "genres"]

    /// The API when it can answer; Subsonic offline (its saved answers), when the API's sign-in
    /// is gone, or when the server can't be reached.
    func throughAPI<T>(_ api: () async throws -> T, else subsonicPath: () async throws -> T) async throws -> T {
        if offline?.isOn == true { return try await subsonicPath() }
        guard await client.tokens.current != nil else { return try await subsonicPath() }
        do {
            return try await api()
        } catch OwnAudioError.network {
            return try await subsonicPath()
        } catch let error as OwnAudioError {
            throw Self.sourceError(error)
        }
    }

    /// The signed-in account's id, asked once.
    func userId() async throws -> String {
        if let known = listener.current.userId { return known }
        let id = try await client.me().id
        listener.setUserId(id)
        return id
    }

    /// The app tells its own playlists by owner name: the account's username for its own, the
    /// owner's id for anyone else's (which no username equals).
    func playlist(_ p: OwnAudioKit.Playlist, mine: String) -> Playlist {
        Playlist(
            id: p.id, name: p.name, comment: p.description, owner: p.ownerId == mine ? subsonic.client.username : p.ownerId,
            songCount: p.trackCount, duration: Int(p.durationMs / 1000), coverArt: p.image != nil ? p.id : nil
        )
    }

    func contributors(_ ids: [String]) async -> [OwnAudioKit.Contributor] {
        await withTaskGroup(of: OwnAudioKit.Contributor?.self) { group in
            for id in ids { group.addTask { try? await client.contributor(id: id) } }
            return await group.reduce(into: []) { if let c = $1 { $0.append(c) } }
        }
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

    // MARK: - Offline edits and live updates

    /// The server takes at most this many changes in one request.
    static let pushBatch = 500

    public func push(_ edits: [OfflineEdit]) async throws {
        guard await client.tokens.current != nil else { throw SourceError.unsupported }
        let changes = edits.map(Self.change)
        do {
            for start in stride(from: 0, to: changes.count, by: Self.pushBatch) {
                _ = try await client.push(Array(changes[start..<min(start + Self.pushBatch, changes.count)]))
            }
        } catch let error as OwnAudioError {
            throw Self.sourceError(error)
        }
    }

    static func change(_ edit: OfflineEdit) -> OfflineChange {
        switch edit.change {
        case .favorite(let kind, let on):
            return .favourite(itemKind(kind), id: edit.itemId, on, at: edit.madeAt, clientId: edit.clientId)
        case .rating(let kind, let rating):
            return .rating(itemKind(kind), id: edit.itemId, rating, at: edit.madeAt, clientId: edit.clientId)
        case .played(let startedAt, let heardSecs):
            return .play(Play(
                clientId: edit.clientId, kind: .track, id: edit.itemId, startedAt: startedAt,
                endedAt: max(edit.madeAt, startedAt), listenedMs: Int64(max(heardSecs, 0) * 1000)
            ))
        }
    }

    static func itemKind(_ kind: FavoriteKind) -> ItemKind {
        switch kind {
        case .song: .track
        case .album: .album
        case .artist: .contributor
        }
    }

    public func libraryChanges() -> AsyncThrowingStream<Void, Error> {
        let events = client.events()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in events where event.type == "library" {
                        continuation.yield()
                    }
                    continuation.finish()
                } catch let error as OwnAudioError {
                    continuation.finish(throwing: Self.sourceError(error))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
        let tracks = decoded("track", OwnAudioKit.Track.self)
        let mapper = RecordMapper(
            contributors: contributors, albums: albums, genres: decoded("genre", OwnAudioKit.Genre.self),
            listener: ListenerState.Values(state)
        )
        // Artists are the contributors credited as one; authors, narrators and hosts are the
        // same records but not this app's.
        var albumCounts: [String: Int] = [:]
        for a in albums.values {
            for c in Set(a.credits.filter { $0.role == "artist" }.map(\.contributorId)) { albumCounts[c, default: 0] += 1 }
        }
        let trackArtists = Set(tracks.values.flatMap { $0.credits.filter { $0.role == "artist" }.map(\.contributorId) })
        let artists = contributors.values
            .filter { albumCounts[$0.id] != nil || trackArtists.contains($0.id) }
            .map { mapper.artist($0, albumCount: albumCounts[$0.id] ?? 0) }
        return (artists, albums.values.map { mapper.album($0) }, tracks.values.map { mapper.song($0) })
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

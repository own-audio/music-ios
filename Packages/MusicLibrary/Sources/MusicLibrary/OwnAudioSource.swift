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
/// phone from its snapshot and change feed; browsing, favorites, ratings, plays, playlists,
/// search, random songs and lyrics; and — signed per song — streams, downloads and covers.
/// Its Subsonic API, which uses the same ids, answers only what v2 has no word for (the "now
/// playing" report, music folders), and — offline, or when the API's sign-in was refused —
/// whatever the API saved nothing for.
public struct OwnAudioSource: MusicSource, ChangeFeedCatalogue, BatchedOfflineEdits, LiveLibraryUpdates {
    public let subsonic: SubsonicSource
    public let client: OwnAudioClient
    let listener: ListenerState
    let records: RecordIndex
    let paging: Paging

    public init(subsonic: SubsonicSource, client: OwnAudioClient, listener: ListenerState = ListenerState(), records: RecordIndex = RecordIndex()) {
        self.subsonic = subsonic
        self.client = client
        self.listener = listener
        self.records = records
        paging = Paging()
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

    // MARK: - Browsing

    public func artists() async throws -> [Artist] {
        try await throughAPI {
            let all = try await client.all { try await client.artists(cursor: $0, limit: Self.pageMax) }
            let mapper = mapper(nil)
            return all.map { mapper.artist($0) }
        } else: {
            try await subsonic.artists()
        }
    }

    /// Oldest first, as a discography reads.
    public func albums(artistId: String) async throws -> [Album] {
        try await throughAPI {
            try await allAlbums { try await client.albums(contributorId: artistId, include: ["contributors"], cursor: $0, limit: Self.pageMax) }
                .sorted { ($0.year ?? 0, $0.name) < ($1.year ?? 0, $1.name) }
        } else: {
            try await subsonic.albums(artistId: artistId)
        }
    }

    public func albums(_ sort: AlbumSort, limit: Int, offset: Int) async throws -> [Album] {
        try await throughAPI {
            switch sort {
            case .name, .newest:
                let order = sort == .newest ? "added" : "title"
                return try await paging.window("albums?sort=\(order)", limit: limit, offset: offset) { cursor, count in
                    let page = try await client.albums(sort: order, include: ["contributors"], cursor: cursor, limit: count)
                    let mapper = mapper(page.included)
                    return (page.items.map { mapper.album($0) }, page.next)
                }
            case .artist, .random:
                let all = try await paging.everyAlbum(fresh: sort == .random && offset == 0) {
                    try await allAlbums { try await client.albums(include: ["contributors"], cursor: $0, limit: Self.pageMax) }
                }
                let ordered = sort == .random ? all.shuffled : all.byArtist
                return Array(ordered.dropFirst(offset).prefix(limit))
            case .recentlyPlayed, .mostPlayed:
                let played = try await client.played(.album, order: sort == .mostPlayed ? "most" : "recent", limit: min(offset + limit, 500)).items
                let wanted = Array(played.dropFirst(offset).prefix(limit))
                let counts = Dictionary(wanted.map { ($0.id, $0.playCount) }) { a, _ in a }
                return try await albums(ids: wanted.map(\.id), playCounts: counts)
            case .favorites:
                let favourites = try await client.all { try await client.favourites(.album, cursor: $0) }
                    .sorted { $0.createdAt > $1.createdAt }
                return try await albums(ids: Array(favourites.dropFirst(offset).prefix(limit)).map(\.id))
            case .highestRated:
                let rated = try await client.all { try await client.ratings(.album, cursor: $0) }
                    .sorted { ($0.rating, $0.updatedAt) > ($1.rating, $1.updatedAt) }
                return try await albums(ids: Array(rated.dropFirst(offset).prefix(limit)).map(\.id))
            }
        } else: {
            try await subsonic.albums(sort, limit: limit, offset: offset)
        }
    }

    public func albums(genre: Genre, limit: Int) async throws -> [Album] {
        try await throughAPI {
            guard let genreId = try await genreId(genre) else { return [] }
            let page = try await client.albums(genreId: genreId, include: ["contributors"], limit: min(max(limit, 1), Self.pageMax))
            let mapper = mapper(page.included)
            return page.items.map { mapper.album($0) }
        } else: {
            try await subsonic.albums(genre: genre, limit: limit)
        }
    }

    public func album(id: String) async throws -> (album: Album, songs: [Song]) {
        try await throughAPI {
            async let answer = client.album(id: id, include: ["contributors"])
            let tracks = try await tracks { try await client.tracks(albumId: id, include: Self.trackIncludes, cursor: $0, limit: Self.pageMax) }
            let album = try await answer
            var mapper = mapper(album.included)
            mapper.albums[album.record.id] = album.record
            return (mapper.album(album.record), tracks)
        } else: {
            try await subsonic.album(id: id)
        }
    }

    public func song(id: String) async throws -> Song {
        try await throughAPI {
            let answer = try await client.track(id: id, include: Self.trackIncludes)
            return mapper(answer.included).song(answer.record)
        } else: {
            try await subsonic.song(id: id)
        }
    }

    public func songs(limit: Int, offset: Int) async throws -> [Song] {
        try await throughAPI {
            try await paging.window("tracks?sort=title", limit: limit, offset: offset) { cursor, count in
                let page = try await client.tracks(sort: "title", include: Self.trackIncludes, cursor: cursor, limit: count)
                let mapper = mapper(page.included)
                return (page.items.map { mapper.song($0) }, page.next)
            }
        } else: {
            try await subsonic.songs(limit: limit, offset: offset)
        }
    }

    public func randomSongs(limit: Int, genre: Genre?) async throws -> [Song] {
        try await throughAPI {
            var genreId: String?
            if let genre {
                guard let id = try await self.genreId(genre) else { return [] }
                genreId = id
            }
            let page = try await client.randomTracks(genreId: genreId, limit: min(max(limit, 1), 500), include: Self.trackIncludes)
            let mapper = mapper(page.included)
            return page.items.map { mapper.song($0) }
        } else: {
            try await subsonic.randomSongs(limit: limit, genre: genre)
        }
    }

    /// By the API's ids; the app also filters by name, which is what it saved from the Subsonic
    /// API and builds its offline genres from, so either is understood.
    public func genres() async throws -> [Genre] {
        try await throughAPI {
            try await client.all { try await client.genres(cursor: $0) }.map { Genre(id: $0.id, name: $0.name) }
        } else: {
            try await subsonic.genres()
        }
    }

    public func search(_ text: String) async throws -> SearchResult {
        try await throughAPI {
            let answer = try await client.search(text, limit: 20, include: Self.trackIncludes)
            var mapper = mapper(answer.included)
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

    // MARK: - Favorites and ratings

    /// Newest first, as they were marked.
    public func favorites() async throws -> FavoritesResult {
        try await throughAPI {
            async let artistIds = favouriteIds(.contributor)
            async let albumIds = favouriteIds(.album)
            let trackIds = try await favouriteIds(.track)
            let songs = try await concurrently(trackIds) { id in
                let answer = try await client.track(id: id, include: Self.trackIncludes)
                return mapper(answer.included).song(answer.record)
            }
            let albums = try await albums(ids: try await albumIds)
            let contributors = try await concurrently(try await artistIds) { try await client.contributor(id: $0) }
            let mapper = mapper(nil)
            return FavoritesResult(artists: contributors.map { mapper.artist($0) }, albums: albums, songs: songs)
        } else: {
            try await subsonic.favorites()
        }
    }

    public func setFavorite(_ kind: FavoriteKind, id: String, _ isFavorite: Bool) async throws {
        try await throughAPI { try await client.setFavourite(Self.itemKind(kind), id: id, isFavorite) } else: {
            try await subsonic.setFavorite(kind, id: id, isFavorite)
        }
        listener.setFavourite(id, isFavorite)
    }

    /// The API rates a track or an album by kind, and the app has only the id: the kind is known
    /// from the record it was shown from, and otherwise tried, a track first.
    public func setRating(id: String, rating: Int) async throws {
        try await throughAPI {
            switch records.kind(of: id) {
            case .album: try await client.setRating(.album, id: id, rating)
            case .track: try await client.setRating(.track, id: id, rating)
            default:
                do {
                    try await client.setRating(.track, id: id, rating)
                } catch OwnAudioError.problem(let p) where p.status == 404 {
                    try await client.setRating(.album, id: id, rating)
                }
            }
        } else: {
            try await subsonic.setRating(id: id, rating: rating)
        }
        listener.setRating(id, rating)
    }

    public func playlists() async throws -> [Playlist] {
        try await throughAPI {
            // Offline the account's id may not be known: every list then reads as someone else's,
            // which only means none can be changed until the server is back.
            let mine = (try? await userId()) ?? ""
            return try await client.all { try await client.playlists(cursor: $0) }.map { playlist($0, mine: mine) }
        } else: {
            try await subsonic.playlists()
        }
    }

    public func playlist(id: String) async throws -> (playlist: Playlist, songs: [Song]) {
        try await throughAPI {
            async let record = client.playlist(id: id)
            var songs: [Song] = []
            var cursor: String?
            repeat {
                let page = try await client.playlistEntries(id: id, include: Self.trackIncludes, cursor: cursor)
                let mapper = mapper(page.included)
                songs += page.items.map { mapper.song($0.track, entryId: $0.id) }
                cursor = page.next
            } while cursor != nil
            let mine = (try? await userId()) ?? ""
            return (playlist(try await record, mine: mine), songs)
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

    // MARK: - Playback reporting

    /// v2 has no "now playing": the Subsonic API's report, which nothing depends on.
    public func reportNowPlaying(songId: String, positionSecs: Double) async throws {
        try? await subsonic.reportNowPlaying(songId: songId, positionSecs: positionSecs)
    }
    public func reportProgress(songId: String, positionSecs: Double, isPaused: Bool) async throws {}
    public func reportStopped(songId: String, positionSecs: Double) async throws {}

    /// A play counted now, heard from `date`. The phone's own id for it makes a retry harmless.
    public func reportPlayed(songId: String, at date: Date) async throws {
        try await throughAPI {
            let now = Date()
            let play = Play(
                clientId: UUID().uuidString, kind: .track, id: songId, startedAt: min(date, now), endedAt: now,
                listenedMs: Int64(max(now.timeIntervalSince(date), 0) * 1000)
            )
            if let refused = try await client.reportPlays([play]).first, refused.status != "ok", refused.status != "duplicate" {
                throw SourceError.server(refused.status)
            }
        } else: {
            try await subsonic.reportPlayed(songId: songId, at: date)
        }
    }

    // MARK: - Streams, downloads and covers

    /// What the player decodes as it streams; anything else the server makes into AAC (or
    /// MP3) first. Ogg and Opus are not among them: Core Audio's stream parser can't read them.
    static let playable = [
        "audio/mpeg", "audio/mp3", "audio/mp4", "audio/x-m4a", "audio/m4a", "audio/aac", "audio/aacp",
        "audio/flac", "audio/x-flac", "audio/wav", "audio/x-wav", "audio/wave", "audio/aiff", "audio/x-aiff",
    ]

    /// A link signed for this song, good for hours: asked for each time a song starts.
    public func streamURL(songId: String, maxBitrate: Int?) async throws -> URL {
        try await throughAPI {
            let capabilities = PlaybackCapabilities(direct: Self.playable, transcode: ["aac", "mp3"], maxBitrateKbps: maxBitrate.map { $0 / 1000 })
            return try await client.playbackInfo(trackId: songId, capabilities: capabilities).url
        } else: {
            subsonic.streamURL(songId: songId, maxBitrate: maxBitrate)
        }
    }

    /// The original, whatever its format: a download is kept, and the player reads whole files
    /// it can't stream.
    public func downloadURL(songId: String) async throws -> URL {
        try await throughAPI {
            try await client.playbackInfo(trackId: songId, capabilities: PlaybackCapabilities(direct: [], transcode: [])).url
        } else: {
            subsonic.downloadURL(songId: songId)
        }
    }

    /// The record's image link at the nearest size the server makes. The link was learned with
    /// the record; one that ran out (or a cover id never seen) is read again.
    public func coverURL(id: String, size: Int) async throws -> URL {
        let link: URL
        if let known = records.image(of: id) {
            link = known
        } else {
            link = try await throughAPI {
                guard let fresh = try await imageLink(id) else { throw SourceError.notFound }
                return fresh
            } else: {
                subsonic.coverURL(id: id, size: size)
            }
            guard link.path.contains("/api/v2/images/") else { return link }
        }
        guard var components = URLComponents(url: link, resolvingAgainstBaseURL: false) else { return link }
        let items = (components.queryItems ?? []).filter { $0.name != "w" }
        components.queryItems = items + [URLQueryItem(name: "w", value: String(RecordIndex.width(for: size)))]
        return components.url ?? link
    }

    /// Reads the record again for its image link: by its known kind, else album, track,
    /// playlist, then contributor (a song's cover is its album's id unless it has its own).
    func imageLink(_ id: String) async throws -> URL? {
        let order: [RecordIndex.Kind] = records.kind(of: id).map { [$0] } ?? [.album, .track, .playlist, .contributor]
        for kind in order {
            do {
                let image: String?
                switch kind {
                case .album: image = try await client.album(id: id, include: []).record.image
                case .track: image = try await client.track(id: id, include: []).record.image
                case .playlist: image = try await client.playlist(id: id).image
                case .contributor: image = try await client.contributor(id: id).image
                }
                records.learn(id, kind, image: image)
                return image.flatMap(URL.init(string:))
            } catch OwnAudioError.problem(let p) where p.status == 404 {
                continue
            }
        }
        return nil
    }

    public func musicLibraries() async throws -> [MusicLibraryInfo] { try await subsonic.musicLibraries() }

    /// Ends both: the API's session (its refresh token) and the Subsonic one.
    public func signOut() async {
        await client.signOut()
        await subsonic.signOut()
    }

    // MARK: - Through the API, or Subsonic

    /// What a track answer brings with it, so songs have their album, artists and genre names.
    static let trackIncludes = ["albums", "contributors", "genres"]
    /// The most the server sends in one page.
    static let pageMax = 500

    /// The API when it can answer — from its saved answers offline or when the server can't be
    /// reached. The Subsonic API when the API's sign-in is gone, or when the API saved nothing
    /// for this yet (an answer the Subsonic API saved before the app moved to v2 still helps).
    func throughAPI<T>(_ api: () async throws -> T, else subsonicPath: () async throws -> T) async throws -> T {
        guard await client.tokens.current != nil else { return try await subsonicPath() }
        do {
            return try await api()
        } catch OwnAudioError.network, OwnAudioError.offline {
            return try await subsonicPath()
        } catch let error as OwnAudioError {
            throw Self.sourceError(error)
        }
    }

    /// A mapper for one answer, with the listener's marks, learning kinds and images as it goes.
    func mapper(_ included: Included?) -> RecordMapper {
        RecordMapper(included, listener: listener.current, index: records)
    }

    /// Every page of albums, mapped page by page with what each brought.
    func allAlbums(_ page: (String?) async throws -> Page<OwnAudioKit.Album>) async throws -> [Album] {
        var out: [Album] = []
        var cursor: String?
        repeat {
            let p = try await page(cursor)
            let mapper = mapper(p.included)
            out += p.items.map { mapper.album($0) }
            cursor = p.next
        } while cursor != nil
        return out
    }

    /// Every page of tracks, mapped page by page.
    func tracks(_ page: (String?) async throws -> Page<OwnAudioKit.Track>) async throws -> [Song] {
        var out: [Song] = []
        var cursor: String?
        repeat {
            let p = try await page(cursor)
            let mapper = mapper(p.included)
            out += p.items.map { mapper.song($0) }
            cursor = p.next
        } while cursor != nil
        return out
    }

    /// Albums by id, in that order; those gone since (a favorite of a deleted album) left out.
    func albums(ids: [String], playCounts: [String: Int] = [:]) async throws -> [Album] {
        try await concurrently(ids) { id in
            let answer = try await client.album(id: id, include: ["contributors"])
            return mapper(answer.included).album(answer.record, playCount: playCounts[id])
        }
    }

    func favouriteIds(_ kind: ItemKind) async throws -> [String] {
        try await client.all { try await client.favourites(kind, cursor: $0) }
            .sorted { $0.createdAt > $1.createdAt }
            .map(\.id)
    }

    /// `body` for each id, a few at a time, results in the ids' order; a 404 drops that one.
    func concurrently<T: Sendable>(_ ids: [String], width: Int = 8, _ body: @escaping @Sendable (String) async throws -> T) async throws -> [T] {
        var results = [T?](repeating: nil, count: ids.count)
        try await withThrowingTaskGroup(of: (Int, T?).self) { group in
            var next = 0
            func add() {
                guard next < ids.count else { return }
                let index = next
                let id = ids[index]
                next += 1
                group.addTask {
                    do {
                        return (index, try await body(id))
                    } catch OwnAudioError.problem(let p) where p.status == 404 {
                        return (index, nil)
                    }
                }
            }
            for _ in 0..<min(width, ids.count) { add() }
            while let (index, value) = try await group.next() {
                results[index] = value
                add()
            }
        }
        return results.compactMap { $0 }
    }

    /// The API's id for a genre the app may know by name (from the Subsonic API, or the library
    /// on the phone) or by id; nil when the server has no such genre.
    func genreId(_ genre: Genre) async throws -> String? {
        if UUID(uuidString: genre.id) != nil { return genre.id }
        let all = try await client.all { try await client.genres(cursor: $0) }
        return all.first { $0.name.caseInsensitiveCompare(genre.name) == .orderedSame }?.id
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
        records.learn(p.id, .playlist, image: p.image)
        return Playlist(
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
            records.update(from: updated)
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
        case .offline: .offline
        }
    }
}

/// Offsets over the API's cursor pages. The app pages by offset; the API by an opaque cursor
/// that names the last item seen (so it stays valid as the library changes). The cursor that
/// starts each offset already reached is kept, so the next page is one request.
final class Paging: @unchecked Sendable {
    /// Per listing, the cursor that starts at an offset; `.some(nil)` marks the end.
    private var cursors: [String: [Int: String?]] = [:]
    private var albums: (byArtist: [Album], shuffled: [Album], loadedAt: Date)?
    private let lock = NSLock()
    /// The whole album list is read again after this long.
    private static let albumsMaxAge: TimeInterval = 10 * 60

    /// `limit` items from `offset`, asking `page(cursor, count)` from the nearest known start.
    func window<T>(_ key: String, limit: Int, offset: Int, page: (String?, Int) async throws -> ([T], String?)) async throws -> [T] {
        var (position, cursor, ended) = nearest(key, offset)
        if ended { return [] }
        var out: [T] = []
        while out.count < limit {
            let count = position < offset ? min(offset - position, OwnAudioSource.pageMax) : min(limit - out.count, OwnAudioSource.pageMax)
            let (items, next) = try await page(cursor, count)
            if position >= offset { out += items }
            position += items.count
            cursor = next
            remember(key, position, next)
            if next == nil || items.isEmpty { break }
        }
        return out
    }

    private func nearest(_ key: String, _ offset: Int) -> (position: Int, cursor: String?, ended: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard let known = cursors[key], let start = known.keys.filter({ $0 <= offset }).max(), let cursor = known[start] else {
            return (0, nil, false)
        }
        return (start, cursor, cursor == nil)
    }

    private func remember(_ key: String, _ position: Int, _ cursor: String?) {
        lock.lock()
        cursors[key, default: [:]][position] = .some(cursor)
        lock.unlock()
    }

    /// Every album, in the two orders the API can't give: by artist, and shuffled. `fresh`
    /// shuffles again (a new random list starts at offset 0).
    func everyAlbum(fresh: Bool, load: () async throws -> [Album]) async throws -> (byArtist: [Album], shuffled: [Album]) {
        var held = lock.withLock { albums }
        if held == nil || held!.loadedAt.timeIntervalSinceNow < -Self.albumsMaxAge {
            let all = try await load()
            let byArtist = all.sorted {
                let a = ($0.artist ?? "", $0.year ?? 0, $0.name), b = ($1.artist ?? "", $1.year ?? 0, $1.name)
                if a.0 != b.0 { return a.0.localizedStandardCompare(b.0) == .orderedAscending }
                if a.1 != b.1 { return a.1 < b.1 }
                return a.2.localizedStandardCompare(b.2) == .orderedAscending
            }
            held = (byArtist, all.shuffled(), Date())
        } else if fresh, let current = held {
            held = (current.byArtist, current.byArtist.shuffled(), current.loadedAt)
        }
        lock.withLock { albums = held }
        return (held!.byArtist, held!.shuffled)
    }
}

import Foundation

/// What a server can do beyond the basics every source has (browse, search, play, favorites,
/// playlists). Screens ask before offering a feature, so a missing one is hidden, not broken.
public struct Capabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Ratings from 1 to 5.
    public static let ratings = Capabilities(rawValue: 1 << 0)
    /// Songs like a song, album or artist, picked by the server.
    public static let instantMix = Capabilities(rawValue: 1 << 1)
    /// The server makes a smaller stream on request.
    public static let lowerBitrate = Capabilities(rawValue: 1 << 2)
    /// The server holds several music libraries and listings can be limited to one.
    public static let libraryChoice = Capabilities(rawValue: 1 << 3)
    /// The server counts plays itself from the playback reports it was sent while playing;
    /// only plays it never heard about (made offline) are reported afterwards.
    public static let countsPlaysFromReports = Capabilities(rawValue: 1 << 4)
}

/// Album orders a source can list in. `highestRated` needs `.ratings`.
public enum AlbumSort: String, Sendable, CaseIterable, Hashable, Codable {
    case name, artist, newest, recentlyPlayed, mostPlayed, random, favorites, highestRated
}

public enum FavoriteKind: Sendable {
    case song, album, artist
}

public enum ConnectionStatus: Equatable, Sendable {
    case ok
    /// Reachable, but the sign-in is refused.
    case rejected
    case unreachable
}

/// The errors screens show, whatever the server.
public enum SourceError: Error, Sendable, Equatable {
    case signInRejected
    case notAllowed
    case notFound
    case http(Int)
    /// The answer couldn't be read; the message says whose protocol was expected.
    case unreadable
    case network
    /// Offline, and this wasn't saved from an earlier visit.
    case offline
    /// The server doesn't have this feature.
    case unsupported
    /// The server's own message.
    case server(String)
}

/// One server, whatever its kind. Every method may throw `SourceError`.
public protocol MusicSource: Sendable {
    var capabilities: Capabilities { get }
    var albumSorts: [AlbumSort] { get }

    func checkConnection() async -> ConnectionStatus

    // Browsing
    func artists() async throws -> [Artist]
    func albums(artistId: String) async throws -> [Album]
    func albums(_ sort: AlbumSort, limit: Int, offset: Int) async throws -> [Album]
    func albums(genre: Genre, limit: Int) async throws -> [Album]
    func album(id: String) async throws -> (album: Album, songs: [Song])
    func song(id: String) async throws -> Song
    func songs(limit: Int, offset: Int) async throws -> [Song]
    func randomSongs(limit: Int, genre: Genre?) async throws -> [Song]
    func genres() async throws -> [Genre]
    func search(_ text: String) async throws -> SearchResult
    func instantMix(itemId: String) async throws -> [Song]

    // Favorites and ratings
    func favorites() async throws -> FavoritesResult
    func setFavorite(_ kind: FavoriteKind, id: String, _ isFavorite: Bool) async throws
    /// 1–5, or 0 to clear.
    func setRating(id: String, rating: Int) async throws

    // Playlists
    func playlists() async throws -> [Playlist]
    func playlist(id: String) async throws -> (playlist: Playlist, songs: [Song])
    func createPlaylist(name: String, songIds: [String]) async throws
    func addToPlaylist(id: String, songIds: [String]) async throws
    func removeFromPlaylist(id: String, entries: [PlaylistEntry]) async throws
    func renamePlaylist(id: String, to name: String) async throws
    func deletePlaylist(id: String) async throws

    // Lyrics: one entry per version (language, synced or plain); empty when there are none.
    func lyrics(for song: Song) async throws -> [Lyrics]

    // Playback reporting
    func reportNowPlaying(songId: String, positionSecs: Double) async throws
    func reportProgress(songId: String, positionSecs: Double, isPaused: Bool) async throws
    func reportStopped(songId: String, positionSecs: Double) async throws
    /// A counted play; `at` is when listening began, for plays reported late.
    func reportPlayed(songId: String, at date: Date) async throws

    // URLs. A server may have to be asked for them (own.audio signs a link per song), so they
    // are async; servers that build them on the phone answer at once.
    /// The audio; with `maxBitrate` (bits per second) a smaller stream where the server makes one.
    func streamURL(songId: String, maxBitrate: Int?) async throws -> URL
    /// The original file, for keeping on the phone.
    func downloadURL(songId: String) async throws -> URL
    func coverURL(id: String, size: Int) async throws -> URL

    // Several music libraries
    func musicLibraries() async throws -> [MusicLibraryInfo]

    // Concerts: a whole concert as one song, with a chapter where each song of the show starts.
    /// Whether the server has them; screens hide Concerts otherwise.
    func supportsConcerts() async -> Bool
    func concerts() async throws -> [Album]
    /// A song's chapters in order; empty for an ordinary song.
    func chapters(songId: String) async throws -> [SongChapter]
    /// Replaces a song's chapters (its owner's); answers them as stored.
    func saveChapters(songId: String, _ chapters: [SongChapter]) async throws -> [SongChapter]
    /// Where the listener stopped in a long song, kept by the server for every device.
    func savedPosition(songId: String) async throws -> Double?
    func savePosition(songId: String, positionSecs: Double) async throws

    /// Ends the session on the server where there is one.
    func signOut() async
}

extension MusicSource {
    public func supportsConcerts() async -> Bool { false }
    public func concerts() async throws -> [Album] { throw SourceError.unsupported }
    public func chapters(songId: String) async throws -> [SongChapter] { [] }
    public func saveChapters(songId: String, _ chapters: [SongChapter]) async throws -> [SongChapter] { throw SourceError.unsupported }
    public func savedPosition(songId: String) async throws -> Double? { nil }
    public func savePosition(songId: String, positionSecs: Double) async throws {}

    public func albums(_ sort: AlbumSort, limit: Int) async throws -> [Album] {
        try await albums(sort, limit: limit, offset: 0)
    }

    public func songs(limit: Int) async throws -> [Song] {
        try await songs(limit: limit, offset: 0)
    }
}

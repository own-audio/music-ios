import Foundation
import OwnAudioKit

/// own.audio's records (ids and credits, no names) as the app's models (names in place), with
/// the listener's favorites and ratings, which the records don't carry.
struct RecordMapper {
    var contributors: [String: OwnAudioKit.Contributor] = [:]
    var albums: [String: OwnAudioKit.Album] = [:]
    var genres: [String: OwnAudioKit.Genre] = [:]
    var listener = ListenerState.Values()

    /// From an answer's `included` records.
    init(_ included: Included?, listener: ListenerState.Values) {
        for c in included?.contributors ?? [] { contributors[c.id] = c }
        for a in included?.albums ?? [] { albums[a.id] = a }
        for g in included?.genres ?? [] { genres[g.id] = g }
        self.listener = listener
    }

    init(contributors: [String: OwnAudioKit.Contributor], albums: [String: OwnAudioKit.Album], genres: [String: OwnAudioKit.Genre], listener: ListenerState.Values) {
        self.contributors = contributors
        self.albums = albums
        self.genres = genres
        self.listener = listener
    }

    /// The credit line as printed: names in order with what joins them.
    func line(_ credits: [Credit], roles: Set<String>) -> String? {
        let parts = credits.filter { roles.contains($0.role) }
        guard !parts.isEmpty else { return nil }
        return parts.map { (contributors[$0.contributorId]?.name ?? "") + $0.joinPhrase }.joined()
    }

    func firstArtist(_ credits: [Credit]) -> String? {
        credits.first { $0.role == "artist" }?.contributorId
    }

    func song(_ t: OwnAudioKit.Track, entryId: String? = nil) -> Song {
        let album = t.albumId.flatMap { albums[$0] }
        let seconds = t.durationMs.map { Int($0 / 1000) }
        return Song(
            id: t.id, title: t.title, album: album?.title, artist: line(t.credits, roles: ["artist", "featured"]),
            albumId: t.albumId, artistId: firstArtist(t.credits), track: t.trackNumber, discNumber: t.discNumber,
            duration: seconds, genre: t.genreIds.first.flatMap { genres[$0]?.name },
            coverArt: t.image != nil ? t.id : (album?.image != nil ? t.albumId : nil),
            suffix: OwnAudioSource.suffix(t.contentType),
            bitRate: (t.sizeBytes ?? 0) > 0 && (seconds ?? 0) > 0 ? Int((t.sizeBytes ?? 0) * 8 / Int64(seconds ?? 1)) : nil,
            isFavorite: listener.favourites.contains(t.id), rating: listener.ratings[t.id], playlistEntryId: entryId
        )
    }

    func album(_ a: OwnAudioKit.Album, playCount: Int? = nil) -> Album {
        Album(
            id: a.id, name: a.title, artist: line(a.credits, roles: ["artist"]), artistId: firstArtist(a.credits),
            songCount: a.trackCount, duration: Int(a.durationMs / 1000), coverArt: a.image != nil ? a.id : nil,
            year: a.releaseDate.flatMap { Int($0.prefix(4)) }, isFavorite: listener.favourites.contains(a.id),
            rating: listener.ratings[a.id], playCount: playCount, dateAdded: a.createdAt
        )
    }

    func artist(_ c: OwnAudioKit.Contributor, albumCount: Int? = nil) -> Artist {
        Artist(
            id: c.id, name: c.name, albumCount: albumCount,
            imageURL: c.image.flatMap { URL(string: $0 + "&w=512") }, isFavorite: listener.favourites.contains(c.id)
        )
    }
}

/// What the listener marked on one own.audio server — favorites and ratings — as the change
/// feed last brought it. Records from the API don't carry it, so answers that bypass the
/// library on the phone (search, playlists, random songs) take it from here; without it they
/// would show every heart as off.
public final class ListenerState: @unchecked Sendable {
    public struct Values: Sendable {
        /// Ids of favorite tracks, albums and artists (one id space: they are UUIDs).
        public var favourites: Set<String> = []
        /// Ratings of tracks and albums, 1 to 5.
        public var ratings: [String: Int] = [:]
        /// The signed-in account, once known: whose playlists are whose.
        public var userId: String?

        public init() {}

        /// From the change feed's `favourite.*` and `rating.*` records.
        public init(_ state: FeedState) {
            for (kind, records) in state.records {
                if kind.hasPrefix("favourite.") {
                    favourites.formUnion(records.keys)
                } else if kind.hasPrefix("rating.") {
                    for (id, record) in records {
                        if case .number(let n)? = record["rating"] { ratings[id] = Int(n) }
                    }
                }
            }
        }
    }

    private let lock = NSLock()
    private var values = Values()

    public init() {}

    public var current: Values {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    /// After the library on the phone synced; keeps the account id already learned.
    public func update(from state: FeedState) {
        lock.lock()
        let userId = values.userId
        values = Values(state)
        values.userId = userId
        lock.unlock()
    }

    func setUserId(_ id: String) {
        lock.lock()
        values.userId = id
        lock.unlock()
    }

    /// A change made here, before the feed brings it back.
    public func setFavourite(_ id: String, _ on: Bool) {
        lock.lock()
        if on { values.favourites.insert(id) } else { values.favourites.remove(id) }
        lock.unlock()
    }

    public func setRating(_ id: String, _ rating: Int) {
        lock.lock()
        values.ratings[id] = rating == 0 ? nil : rating
        lock.unlock()
    }
}

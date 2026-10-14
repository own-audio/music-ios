import Foundation

// One set of models for every kind of server. Ids are the server's own; a cover is named by
// the id the server uses for its image (`MusicSource.coverURL`).

public struct Artist: Codable, Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    /// Not every listing sends it.
    public let albumCount: Int?
    /// An image id for `coverURL`, where the server keeps artist pictures itself.
    public let coverArt: String?
    /// A ready image URL, where the server hands one out instead (Navidrome does).
    public let imageURL: URL?
    public let isFavorite: Bool

    public init(
        id: String, name: String, albumCount: Int? = nil, coverArt: String? = nil,
        imageURL: URL? = nil, isFavorite: Bool = false
    ) {
        self.id = id
        self.name = name
        self.albumCount = albumCount
        self.coverArt = coverArt
        self.imageURL = imageURL
        self.isFavorite = isFavorite
    }

    /// `imageURL` asked for at `size` pixels, when the URL carries a size parameter
    /// (Navidrome's do; otherwise the URL is returned as it is).
    public func imageURL(size: Int) -> URL? {
        guard let imageURL, var components = URLComponents(url: imageURL, resolvingAgainstBaseURL: false),
              let items = components.queryItems, items.contains(where: { $0.name == "size" })
        else { return imageURL }
        components.queryItems = items.map { $0.name == "size" ? URLQueryItem(name: "size", value: String(size)) : $0 }
        return components.url ?? imageURL
    }
}

public struct Album: Codable, Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let artist: String?
    public let artistId: String?
    public let songCount: Int
    /// Seconds.
    public let duration: Int?
    public let coverArt: String?
    public let year: Int?
    public let genre: String?
    public let isFavorite: Bool
    /// 1–5, where the server has ratings.
    public let rating: Int?
    public let playCount: Int?
    public let dateAdded: Date?

    public init(
        id: String, name: String, artist: String? = nil, artistId: String? = nil, songCount: Int = 0,
        duration: Int? = nil, coverArt: String? = nil, year: Int? = nil, genre: String? = nil,
        isFavorite: Bool = false, rating: Int? = nil, playCount: Int? = nil, dateAdded: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.artist = artist
        self.artistId = artistId
        self.songCount = songCount
        self.duration = duration
        self.coverArt = coverArt
        self.year = year
        self.genre = genre
        self.isFavorite = isFavorite
        self.rating = rating
        self.playCount = playCount
        self.dateAdded = dateAdded
    }
}

/// Loudness correction in dB and peaks (1.0 = full scale), from ReplayGain tags or a
/// server's own measurement.
public struct Gain: Codable, Sendable, Hashable {
    public let track: Double?
    public let album: Double?
    public let trackPeak: Double?
    public let albumPeak: Double?

    public init(track: Double? = nil, album: Double? = nil, trackPeak: Double? = nil, albumPeak: Double? = nil) {
        self.track = track
        self.album = album
        self.trackPeak = trackPeak
        self.albumPeak = albumPeak
    }

    public var isEmpty: Bool { track == nil && album == nil }
}

public struct Song: Codable, Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let album: String?
    public let artist: String?
    public let albumId: String?
    public let artistId: String?
    public let track: Int?
    public let discNumber: Int?
    /// Seconds.
    public let duration: Int?
    public let genre: String?
    public let coverArt: String?
    /// The file's format, e.g. "mp3", "flac".
    public let suffix: String?
    /// Bits per second.
    public let bitRate: Int?
    public let isFavorite: Bool
    public let rating: Int?
    public let playCount: Int?
    public let gain: Gain?
    /// This entry's own id within a playlist, where the server has one (Jellyfin); removing an
    /// entry goes by it, since a song can be in a playlist twice.
    public let playlistEntryId: String?
    /// Whose it is and who hears it, where the server keeps a household (own.audio); nil
    /// elsewhere.
    public let sharing: Sharing?

    public init(
        id: String, title: String, album: String? = nil, artist: String? = nil,
        albumId: String? = nil, artistId: String? = nil, track: Int? = nil, discNumber: Int? = nil,
        duration: Int? = nil, genre: String? = nil, coverArt: String? = nil, suffix: String? = nil,
        bitRate: Int? = nil, isFavorite: Bool = false, rating: Int? = nil, playCount: Int? = nil,
        gain: Gain? = nil, playlistEntryId: String? = nil, sharing: Sharing? = nil
    ) {
        self.id = id
        self.title = title
        self.album = album
        self.artist = artist
        self.albumId = albumId
        self.artistId = artistId
        self.track = track
        self.discNumber = discNumber
        self.duration = duration
        self.genre = genre
        self.coverArt = coverArt
        self.suffix = suffix
        self.bitRate = bitRate
        self.isFavorite = isFavorite
        self.rating = rating
        self.playCount = playCount
        self.gain = gain
        self.playlistEntryId = playlistEntryId
        self.sharing = sharing
    }
}

/// Who a song or playlist is for, on a server with a household. "Private" means only that it
/// isn't shared: nothing is locked.
public enum Sharing: String, Codable, Sendable, Hashable {
    /// The listener's own, kept to themselves.
    case mine
    /// The listener's own, shared with the household.
    case shared
    /// Someone else's in the household, shared with everyone.
    case household

    public var isMine: Bool { self != .household }
}

public struct Playlist: Codable, Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let comment: String?
    /// The owner's username where the server says; edits are offered on one's own.
    public let owner: String?
    /// What to call the owner where `owner` is not a name (own.audio gives an id); empty when
    /// the name is not known, which shows no owner.
    public let ownerName: String?
    /// Shared with the household, where the server keeps one (own.audio); nil elsewhere.
    public let isShared: Bool?
    public let songCount: Int
    /// Seconds; some servers always send 0.
    public let duration: Int?
    public let coverArt: String?

    public init(
        id: String, name: String, comment: String? = nil, owner: String? = nil, ownerName: String? = nil,
        isShared: Bool? = nil, songCount: Int = 0, duration: Int? = nil, coverArt: String? = nil
    ) {
        self.id = id
        self.name = name
        self.comment = comment
        self.owner = owner
        self.ownerName = ownerName
        self.isShared = isShared
        self.songCount = songCount
        self.duration = duration
        self.coverArt = coverArt
    }
}

/// A position in a playlist: Subsonic removes by position, Jellyfin by the entry's own id.
public struct PlaylistEntry: Sendable, Hashable {
    public let index: Int
    public let entryId: String?

    public init(index: Int, entryId: String?) {
        self.index = index
        self.entryId = entryId
    }
}

public struct Genre: Codable, Sendable, Hashable, Identifiable {
    /// What the server filters by: the name on Subsonic, an id on Jellyfin.
    public let id: String
    public let name: String
    public let albumCount: Int?
    public let songCount: Int?

    public init(id: String, name: String, albumCount: Int? = nil, songCount: Int? = nil) {
        self.id = id
        self.name = name
        self.albumCount = albumCount
        self.songCount = songCount
    }
}

public struct Lyrics: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        public let startMs: Int?
        public let text: String

        public init(startMs: Int?, text: String) {
            self.startMs = startMs
            self.text = text
        }
    }

    public let lines: [Line]
    public let isSynced: Bool
    /// ISO 639 code where the server says; "xxx" means unknown.
    public let language: String?
    public let offsetMs: Int

    public init(lines: [Line], isSynced: Bool, language: String? = nil, offsetMs: Int = 0) {
        self.lines = lines
        self.isSynced = isSynced
        self.language = language
        self.offsetMs = offsetMs
    }

    /// The line to highlight at `seconds`, for synced lyrics.
    public func lineIndex(at seconds: Double) -> Int? {
        guard isSynced else { return nil }
        let ms = Int(seconds * 1000) - offsetMs
        return lines.lastIndex { ($0.startMs ?? .max) <= ms }
    }
}

public struct SearchResult: Sendable {
    public let artists: [Artist]
    public let albums: [Album]
    public let songs: [Song]

    public init(artists: [Artist], albums: [Album], songs: [Song]) {
        self.artists = artists
        self.albums = albums
        self.songs = songs
    }

    public var isEmpty: Bool { artists.isEmpty && albums.isEmpty && songs.isEmpty }
}

public struct FavoritesResult: Sendable {
    public let artists: [Artist]
    public let albums: [Album]
    public let songs: [Song]

    public init(artists: [Artist], albums: [Album], songs: [Song]) {
        self.artists = artists
        self.albums = albums
        self.songs = songs
    }

    public var isEmpty: Bool { artists.isEmpty && albums.isEmpty && songs.isEmpty }
}

/// A music library on a server that has several (Jellyfin).
public struct MusicLibraryInfo: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

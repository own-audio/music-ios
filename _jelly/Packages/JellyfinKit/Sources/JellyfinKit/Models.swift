import Foundation

// The app's view of a Jellyfin music library. Field names follow own.audio for Subsonic's
// models where the meaning is the same, so the two apps' screens stay alike. Item ids are
// Jellyfin's; a cover is named by the id of the item that holds the image.

public struct Artist: Codable, Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    /// Not every listing sends it.
    public let albumCount: Int?
    /// Set when the artist has its own picture.
    public let imageId: String?
    public let isFavorite: Bool

    public init(id: String, name: String, albumCount: Int? = nil, imageId: String? = nil, isFavorite: Bool = false) {
        self.id = id
        self.name = name
        self.albumCount = albumCount
        self.imageId = imageId
        self.isFavorite = isFavorite
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
    public let playCount: Int?
    public let dateAdded: Date?

    public init(
        id: String, name: String, artist: String?, artistId: String?, songCount: Int,
        duration: Int?, coverArt: String?, year: Int?, genre: String? = nil,
        isFavorite: Bool = false, playCount: Int? = nil, dateAdded: Date? = nil
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
        self.playCount = playCount
        self.dateAdded = dateAdded
    }
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
    /// The file's container, e.g. "mp3", "flac".
    public let suffix: String?
    /// Bits per second.
    public let bitRate: Int?
    public let isFavorite: Bool
    public let playCount: Int?
    /// The loudness correction the server measured, in dB. Absent until the library's
    /// "normalization" option has run.
    public let normalizationGain: Double?
    public let hasLyrics: Bool
    /// This entry's id within a playlist; removing from a playlist goes by it, since the same
    /// song can be in a playlist twice.
    public let playlistItemId: String?

    public init(
        id: String, title: String, album: String? = nil, artist: String? = nil,
        albumId: String? = nil, artistId: String? = nil, track: Int? = nil, discNumber: Int? = nil,
        duration: Int? = nil, genre: String? = nil, coverArt: String? = nil, suffix: String? = nil,
        bitRate: Int? = nil, isFavorite: Bool = false, playCount: Int? = nil,
        normalizationGain: Double? = nil, hasLyrics: Bool = false, playlistItemId: String? = nil
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
        self.playCount = playCount
        self.normalizationGain = normalizationGain
        self.hasLyrics = hasLyrics
        self.playlistItemId = playlistItemId
    }
}

public struct Playlist: Codable, Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let songCount: Int
    /// Seconds.
    public let duration: Int?
    public let coverArt: String?

    public init(id: String, name: String, songCount: Int, duration: Int?, coverArt: String?) {
        self.id = id
        self.name = name
        self.songCount = songCount
        self.duration = duration
        self.coverArt = coverArt
    }
}

public struct Genre: Codable, Sendable, Hashable, Identifiable {
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

/// A music library on the server. A server can have several.
public struct MusicLibrary: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
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

    public init(lines: [Line], isSynced: Bool) {
        self.lines = lines
        self.isSynced = isSynced
    }

    /// The line to highlight at `seconds`, for synced lyrics.
    public func lineIndex(at seconds: Double) -> Int? {
        guard isSynced else { return nil }
        let ms = Int(seconds * 1000)
        return lines.lastIndex { ($0.startMs ?? .max) <= ms }
    }
}

/// What `System/Info/Public` says, before signing in.
public struct ServerInfo: Codable, Sendable, Equatable {
    public let id: String
    public let serverName: String
    public let version: String

    enum CodingKeys: String, CodingKey {
        case id = "Id", serverName = "ServerName", version = "Version"
    }
}

/// A successful sign-in.
public struct Session: Codable, Sendable, Equatable {
    public let userId: String
    public let userName: String
    public let accessToken: String
    public let serverId: String
}

/// Album orders the server can list in.
public enum AlbumSort: String, Sendable, CaseIterable, Hashable {
    case name, artist, newest, recentlyPlayed, mostPlayed, random, favorites
}

// MARK: - Wire format

/// `BaseItemDto`, cut down to what a music player reads.
struct ItemDTO: Decodable {
    struct NameId: Decodable {
        let name: String?
        let id: String?
        enum CodingKeys: String, CodingKey { case name = "Name", id = "Id" }
    }

    struct UserData: Decodable {
        let isFavorite: Bool?
        let playCount: Int?
        enum CodingKeys: String, CodingKey { case isFavorite = "IsFavorite", playCount = "PlayCount" }
    }

    struct ImageTags: Decodable {
        let primary: String?
        enum CodingKeys: String, CodingKey { case primary = "Primary" }
    }

    struct MediaSource: Decodable {
        let container: String?
        let bitrate: Int?
        enum CodingKeys: String, CodingKey { case container = "Container", bitrate = "Bitrate" }
    }

    let id: String
    let name: String?
    let type: String?
    let album: String?
    let albumId: String?
    let albumArtist: String?
    let albumArtists: [NameId]?
    let artistItems: [NameId]?
    let albumPrimaryImageTag: String?
    let imageTags: ImageTags?
    let runTimeTicks: Int64?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let productionYear: Int?
    let genres: [String]?
    let childCount: Int?
    let albumCount: Int?
    let songCount: Int?
    let userData: UserData?
    let container: String?
    let mediaSources: [MediaSource]?
    let normalizationGain: Double?
    let hasLyrics: Bool?
    let playlistItemId: String?
    let dateCreated: Date?
    let collectionType: String?
    let mediaType: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", type = "Type", album = "Album", albumId = "AlbumId"
        case albumArtist = "AlbumArtist", albumArtists = "AlbumArtists", artistItems = "ArtistItems"
        case albumPrimaryImageTag = "AlbumPrimaryImageTag", imageTags = "ImageTags"
        case runTimeTicks = "RunTimeTicks", indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber", productionYear = "ProductionYear"
        case genres = "Genres", childCount = "ChildCount", albumCount = "AlbumCount"
        case songCount = "SongCount", userData = "UserData", container = "Container"
        case mediaSources = "MediaSources", normalizationGain = "NormalizationGain"
        case hasLyrics = "HasLyrics", playlistItemId = "PlaylistItemId"
        case dateCreated = "DateCreated", collectionType = "CollectionType", mediaType = "MediaType"
    }

    /// Libraries with sloppy tags send names made of spaces; those count as no name.
    var trimmedName: String { (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 100-nanosecond ticks to whole seconds.
    var seconds: Int? { runTimeTicks.map { Int(($0 + 5_000_000) / 10_000_000) } }

    var asArtist: Artist {
        Artist(
            id: id, name: trimmedName, albumCount: albumCount ?? childCount,
            imageId: imageTags?.primary != nil ? id : nil, isFavorite: userData?.isFavorite ?? false
        )
    }

    var asAlbum: Album {
        let artist = albumArtists?.first ?? artistItems?.first
        return Album(
            id: id, name: trimmedName, artist: albumArtist ?? artist?.name, artistId: artist?.id,
            songCount: childCount ?? songCount ?? 0, duration: seconds,
            coverArt: imageTags?.primary != nil ? id : nil, year: productionYear,
            genre: genres?.first, isFavorite: userData?.isFavorite ?? false,
            playCount: userData?.playCount, dateAdded: dateCreated
        )
    }

    var asSong: Song {
        let source = mediaSources?.first
        let cover: String? = imageTags?.primary != nil ? id : (albumPrimaryImageTag != nil ? albumId : nil)
        // The disc number is 0 on files without a disc tag; that isn't a real disc.
        let disc = parentIndexNumber.flatMap { $0 > 0 ? $0 : nil }
        return Song(
            id: id, title: trimmedName, album: album, artist: artistItems?.first?.name ?? albumArtist,
            albumId: albumId, artistId: artistItems?.first?.id ?? albumArtists?.first?.id,
            track: indexNumber, discNumber: disc, duration: seconds, genre: genres?.first,
            coverArt: cover, suffix: container ?? source?.container, bitRate: source?.bitrate,
            isFavorite: userData?.isFavorite ?? false, playCount: userData?.playCount,
            normalizationGain: normalizationGain, hasLyrics: hasLyrics ?? false,
            playlistItemId: playlistItemId
        )
    }

    var asPlaylist: Playlist {
        Playlist(
            id: id, name: trimmedName, songCount: childCount ?? 0, duration: seconds,
            coverArt: imageTags?.primary != nil ? id : nil
        )
    }

    var asGenre: Genre {
        Genre(id: id, name: name ?? "", albumCount: albumCount, songCount: songCount)
    }
}

struct ItemsResponse: Decodable {
    let items: [ItemDTO]
    let totalRecordCount: Int?
    enum CodingKeys: String, CodingKey { case items = "Items", totalRecordCount = "TotalRecordCount" }
}

struct AuthResponse: Decodable {
    struct User: Decodable {
        let id: String
        let name: String
        enum CodingKeys: String, CodingKey { case id = "Id", name = "Name" }
    }

    let user: User
    let accessToken: String
    let serverId: String
    enum CodingKeys: String, CodingKey { case user = "User", accessToken = "AccessToken", serverId = "ServerId" }

    var session: Session { Session(userId: user.id, userName: user.name, accessToken: accessToken, serverId: serverId) }
}

struct LyricsDTO: Decodable {
    struct Line: Decodable {
        let text: String?
        let start: Int64?
        enum CodingKeys: String, CodingKey { case text = "Text", start = "Start" }
    }

    let lyrics: [Line]?
    enum CodingKeys: String, CodingKey { case lyrics = "Lyrics" }
}

struct QuickConnectDTO: Decodable {
    let secret: String
    let code: String
    let authenticated: Bool
    enum CodingKeys: String, CodingKey { case secret = "Secret", code = "Code", authenticated = "Authenticated" }
}

struct CreatedDTO: Decodable {
    let id: String
    enum CodingKeys: String, CodingKey { case id = "Id" }
}

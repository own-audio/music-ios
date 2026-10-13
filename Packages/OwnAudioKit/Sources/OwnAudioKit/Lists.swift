import Foundation

// Playlists, search, random tracks, the listener's plays and lyrics (server 1.0.0-beta.11, the
// API's V10).

/// A playlist: its owner's, private or shared with the household.
public struct Playlist: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let description: String?
    /// `private` or `family`.
    public let visibility: String
    public let ownerId: String
    /// Of the entries the caller can see.
    public let trackCount: Int
    public let durationMs: Int64
    public let image: String?
    public let createdAt: Date
    public let updatedAt: Date
}

/// One place in a playlist, with its own id: a track can be in a playlist twice.
public struct PlaylistEntry: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let position: Int
    public let addedAt: Date
    public let track: Track
}

public struct SearchAnswer: Decodable, Sendable {
    public let artists: [Contributor]
    public let albums: [Album]
    public let tracks: [Track]
    public let included: Included?
}

/// How often and when the caller played a track or an album.
public struct Played: Decodable, Sendable, Equatable {
    public let kind: String
    public let id: String
    public let playCount: Int
    public let lastPlayedAt: Date
}

public struct TrackLyrics: Decodable, Sendable, Equatable {
    public struct Line: Decodable, Sendable, Equatable {
        public let startMs: Int?
        public let text: String
    }

    /// As stored; nil when the track has none.
    public let text: String?
    public let synced: Bool
    public let lines: [Line]
}

extension OwnAudioClient {
    // MARK: - Playlists

    public func playlists(cursor: String? = nil, limit: Int = 500) async throws -> Page<Playlist> {
        try await get("playlists", query: ["cursor": cursor, "limit": String(limit)])
    }

    public func playlist(id: String) async throws -> Playlist {
        try await get("playlists/\(id)")
    }

    /// In order, each with its track; `include` as for tracks.
    public func playlistEntries(id: String, include: [String] = [], cursor: String? = nil, limit: Int = 500) async throws -> Page<PlaylistEntry> {
        try await get("playlists/\(id)/entries", query: [
            "include": include.isEmpty ? nil : include.joined(separator: ","), "cursor": cursor, "limit": String(limit),
        ])
    }

    public func createPlaylist(name: String, description: String? = nil, visibility: String? = nil, trackIds: [String] = []) async throws -> Playlist {
        struct Body: Encodable { let name: String; let description: String?; let visibility: String?; let trackIds: [String] }
        return try await call("POST", "playlists", body: Body(name: name, description: description, visibility: visibility, trackIds: trackIds))
    }

    public func renamePlaylist(id: String, to name: String) async throws -> Playlist {
        struct Body: Encodable { let name: String }
        return try await call("PATCH", "playlists/\(id)", body: Body(name: name))
    }

    public func deletePlaylist(id: String) async throws {
        try await send("DELETE", "playlists/\(id)", body: Optional<Empty>.none)
    }

    /// Appends in order; tracks the caller can't see are left out.
    public func addToPlaylist(id: String, trackIds: [String]) async throws -> Playlist {
        struct Body: Encodable { let trackIds: [String] }
        return try await call("POST", "playlists/\(id)/entries", body: Body(trackIds: trackIds))
    }

    public func removeFromPlaylist(id: String, entryId: String) async throws {
        try await send("DELETE", "playlists/\(id)/entries/\(entryId)", body: Optional<Empty>.none)
    }

    /// `entryIds` first, in that order; the others after them as they were.
    public func orderPlaylist(id: String, entryIds: [String]) async throws {
        struct Body: Encodable { let entryIds: [String] }
        try await send("PUT", "playlists/\(id)/entries/order", body: Body(entryIds: entryIds))
    }

    // MARK: - Finding music

    /// `types`: `artists`, `albums`, `tracks` (all by default).
    public func search(_ text: String, types: [String] = [], limit: Int = 20, include: [String] = []) async throws -> SearchAnswer {
        try await get("search", query: [
            "q": text, "types": types.isEmpty ? nil : types.joined(separator: ","), "limit": String(limit),
            "include": include.isEmpty ? nil : include.joined(separator: ","),
        ])
    }

    /// A new draw on every call.
    public func randomTracks(genreId: String? = nil, limit: Int = 50, include: [String] = []) async throws -> Page<Track> {
        try await get("tracks/random", query: [
            "genre_id": genreId, "limit": String(limit), "include": include.isEmpty ? nil : include.joined(separator: ","),
        ])
    }

    /// The caller's own plays of `track`s or `album`s: `recent` or `most` first.
    public func played(_ kind: ItemKind, order: String = "recent", limit: Int = 100) async throws -> Page<Played> {
        try await get("me/played", query: ["kind": kind.rawValue, "order": order, "limit": String(limit)])
    }

    public func lyrics(trackId: String) async throws -> TrackLyrics {
        try await get("tracks/\(trackId)/lyrics")
    }
}

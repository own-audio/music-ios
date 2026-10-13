import Foundation

// Smart playlists (server 1.0.0-beta.13, the API's V11): a saved rule, worked out for whoever
// plays it.

/// What a smart playlist holds: the server's rule, field for field. What is left out is not a
/// condition.
public struct SmartRule: Codable, Sendable, Equatable, Hashable {
    public struct Names: Codable, Sendable, Equatable, Hashable {
        public var include: [String]
        public var exclude: [String]

        public init(include: [String] = [], exclude: [String] = []) {
            self.include = include
            self.exclude = exclude
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            include = try c.decodeIfPresent([String].self, forKey: .include) ?? []
            exclude = try c.decodeIfPresent([String].self, forKey: .exclude) ?? []
        }
    }

    public struct Filters: Codable, Sendable, Equatable, Hashable {
        /// Inclusive, beats per minute.
        public var bpm: [Double]?
        /// Inclusive, 0 to 1, relative to this library.
        public var energy: [Double]?
        /// Genre names, any case.
        public var genres: Names?
        /// Artist names, any case.
        public var artists: Names?
        /// Only favorites.
        public var starred: Bool?
        public var minRating: Int?
        /// Not played by the listener in this many days.
        public var notPlayedDays: Int?
        /// Added in the last this many days.
        public var addedDays: Int?
        /// Played by others in the household, never by the listener.
        public var playedByOthersNotMe: Bool?

        public init() {}
    }

    public enum Limit: Codable, Sendable, Equatable, Hashable {
        case count(Int)
        case minutes(Int)

        private enum CodingKeys: String, CodingKey { case kind, n, minutes }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .kind) {
            case "duration": self = .minutes(try c.decode(Int.self, forKey: .minutes))
            default: self = .count(try c.decode(Int.self, forKey: .n))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .count(let n):
                try c.encode("count", forKey: .kind)
                try c.encode(n, forKey: .n)
            case .minutes(let m):
                try c.encode("duration", forKey: .kind)
                try c.encode(m, forKey: .minutes)
            }
        }
    }

    /// The energy over the playlist.
    public enum Arc: String, Codable, Sendable, CaseIterable, Hashable {
        case none
        case warmupSustainCooldown = "warmup-sustain-cooldown"
        case build
        case unwind
    }

    public enum Sort: String, Codable, Sendable, CaseIterable, Hashable {
        case weightedRandom = "weighted-random"
        case weight
        case leastRecentlyPlayed = "least-recently-played"
        case random
    }

    public struct Sequence: Codable, Sendable, Equatable, Hashable {
        public var maxPerArtist: Int
        public var noConsecutiveArtist: Bool

        public init(maxPerArtist: Int = 2, noConsecutiveArtist: Bool = true) {
            self.maxPerArtist = maxPerArtist
            self.noConsecutiveArtist = noConsecutiveArtist
        }
    }

    public var filters = Filters()
    public var limit = Limit.count(50)
    public var arc = Arc.none
    public var sequence = Sequence()
    public var sort = Sort.weightedRandom

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filters = try c.decodeIfPresent(Filters.self, forKey: .filters) ?? Filters()
        limit = try c.decodeIfPresent(Limit.self, forKey: .limit) ?? .count(50)
        arc = try c.decodeIfPresent(Arc.self, forKey: .arc) ?? .none
        sequence = try c.decodeIfPresent(Sequence.self, forKey: .sequence) ?? Sequence()
        sort = try c.decodeIfPresent(Sort.self, forKey: .sort) ?? .weightedRandom
    }
}

public struct SmartPlaylist: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let description: String?
    public let rule: SmartRule
    /// `dynamic`, or `frozen` once made into an ordinary playlist.
    public let mode: String
    /// `private` or `family`.
    public let visibility: String
    public let ownerId: String
    public let createdAt: Date
    public let updatedAt: Date
}

public struct SmartPreset: Decodable, Sendable, Equatable, Identifiable {
    public var id: String { slug }
    public let slug: String
    public let name: String
    public let rule: SmartRule
}

/// What a rule holds now, in the order to play it.
public struct ResolvedRule: Decodable, Sendable {
    public let items: [Track]
    public let durationMs: Int64
    /// How many tracks matched before sequencing.
    public let candidates: Int
    public let included: Included?
}

extension OwnAudioClient {
    public func smartPlaylists() async throws -> [SmartPlaylist] {
        let page: Page<SmartPlaylist> = try await get("smart-playlists")
        return page.items
    }

    public func smartPlaylist(id: String) async throws -> SmartPlaylist {
        try await get("smart-playlists/\(id)")
    }

    public func smartPresets() async throws -> [SmartPreset] {
        try await get("smart-playlists/presets")
    }

    /// A rule tried without saving it.
    public func resolve(_ rule: SmartRule, include: [String] = []) async throws -> ResolvedRule {
        struct Body: Encodable { let rule: SmartRule }
        return try await call("POST", "smart-playlists/resolve", query: ["include": include.isEmpty ? nil : include.joined(separator: ",")], body: Body(rule: rule))
    }

    /// A saved one, for the caller; a new draw each time.
    public func resolveSmartPlaylist(id: String, include: [String] = []) async throws -> ResolvedRule {
        try await call("POST", "smart-playlists/\(id)/resolve", query: ["include": include.isEmpty ? nil : include.joined(separator: ",")], body: Optional<Empty>.none)
    }

    public func createSmartPlaylist(name: String, rule: SmartRule, visibility: String = "private") async throws -> SmartPlaylist {
        struct Body: Encodable { let name: String; let rule: SmartRule; let visibility: String }
        return try await call("POST", "smart-playlists", body: Body(name: name, rule: rule, visibility: visibility))
    }

    public func updateSmartPlaylist(id: String, name: String, rule: SmartRule, visibility: String) async throws -> SmartPlaylist {
        struct Body: Encodable { let name: String; let rule: SmartRule; let visibility: String }
        return try await call("PATCH", "smart-playlists/\(id)", body: Body(name: name, rule: rule, visibility: visibility))
    }

    public func deleteSmartPlaylist(id: String) async throws {
        try await send("DELETE", "smart-playlists/\(id)", body: Optional<Empty>.none)
    }

    /// Made into an ordinary playlist with what the rule holds now.
    public func freezeSmartPlaylist(id: String, name: String? = nil) async throws -> Playlist {
        struct Body: Encodable { let name: String? }
        return try await call("POST", "smart-playlists/\(id)/freeze", body: Body(name: name))
    }
}

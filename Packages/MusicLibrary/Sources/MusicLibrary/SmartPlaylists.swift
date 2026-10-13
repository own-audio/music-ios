import Foundation
import OwnAudioKit

/// A smart playlist's rule: what own.audio's API takes, field for field.
public typealias SmartRule = OwnAudioKit.SmartRule

/// A saved rule. What it holds is worked out each time it is played, from the listener's own
/// history: shared with the household, it is a different list for each member.
public struct SmartPlaylistInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let rule: SmartRule
    public let isShared: Bool
    /// The listener's own: only they change or delete it.
    public let isMine: Bool
    /// Made into an ordinary playlist; the rule is kept.
    public let isFrozen: Bool

    public init(id: String, name: String, rule: SmartRule, isShared: Bool, isMine: Bool, isFrozen: Bool) {
        self.id = id
        self.name = name
        self.rule = rule
        self.isShared = isShared
        self.isMine = isMine
        self.isFrozen = isFrozen
    }
}

/// A ready-made rule from the server, the same for everyone.
public struct SmartPresetInfo: Identifiable, Hashable, Sendable {
    public var id: String { slug }
    public let slug: String
    public let name: String
    public let rule: SmartRule

    public init(slug: String, name: String, rule: SmartRule) {
        self.slug = slug
        self.name = name
        self.rule = rule
    }
}

/// What a rule holds now, in the order to play it.
public struct SmartResult: Sendable {
    public let songs: [Song]
    /// How many songs matched before the rule's length and artist spacing were applied.
    public let candidates: Int
    /// Seconds.
    public let duration: Int
}

/// A server with smart playlists (own.audio from 1.0.0-beta.13). One without them answers
/// `SourceError.notFound` or `.unsupported`, and the app shows none.
public protocol SmartPlaylistSource: MusicSource {
    func smartPlaylists() async throws -> [SmartPlaylistInfo]
    func smartPresets() async throws -> [SmartPresetInfo]
    /// Try a rule without saving it.
    func resolve(_ rule: SmartRule) async throws -> SmartResult
    /// A saved one, for the listener: a new draw each time.
    func resolve(smartPlaylistId id: String) async throws -> SmartResult
    func saveSmartPlaylist(name: String, rule: SmartRule, shared: Bool) async throws -> SmartPlaylistInfo
    func updateSmartPlaylist(id: String, name: String, rule: SmartRule, shared: Bool) async throws -> SmartPlaylistInfo
    func deleteSmartPlaylist(id: String) async throws
    /// Makes what it holds now into an ordinary playlist.
    func freezeSmartPlaylist(id: String, name: String?) async throws
}

extension OwnAudioSource: SmartPlaylistSource {
    private func api<T>(_ work: () async throws -> T) async throws -> T {
        if offline?.isOn == true { throw SourceError.offline }
        guard await client.tokens.current != nil else { throw SourceError.unsupported }
        do {
            return try await work()
        } catch let error as OwnAudioError {
            throw Self.sourceError(error)
        }
    }

    private func info(_ p: OwnAudioKit.SmartPlaylist, mine: String) -> SmartPlaylistInfo {
        SmartPlaylistInfo(id: p.id, name: p.name, rule: p.rule, isShared: p.visibility == "family", isMine: p.ownerId == mine, isFrozen: p.mode == "frozen")
    }

    private func result(_ r: ResolvedRule) -> SmartResult {
        let mapper = RecordMapper(r.included, listener: listener.current)
        return SmartResult(songs: r.items.map { mapper.song($0) }, candidates: r.candidates, duration: Int(r.durationMs / 1000))
    }

    public func smartPlaylists() async throws -> [SmartPlaylistInfo] {
        try await api {
            let mine = try await userId()
            return try await client.smartPlaylists().map { info($0, mine: mine) }
        }
    }

    public func smartPresets() async throws -> [SmartPresetInfo] {
        try await api { try await client.smartPresets().map { SmartPresetInfo(slug: $0.slug, name: $0.name, rule: $0.rule) } }
    }

    public func resolve(_ rule: SmartRule) async throws -> SmartResult {
        try await api { result(try await client.resolve(rule, include: Self.trackIncludes)) }
    }

    public func resolve(smartPlaylistId id: String) async throws -> SmartResult {
        try await api { result(try await client.resolveSmartPlaylist(id: id, include: Self.trackIncludes)) }
    }

    public func saveSmartPlaylist(name: String, rule: SmartRule, shared: Bool) async throws -> SmartPlaylistInfo {
        try await api {
            let mine = try await userId()
            return info(try await client.createSmartPlaylist(name: name, rule: rule, visibility: shared ? "family" : "private"), mine: mine)
        }
    }

    public func updateSmartPlaylist(id: String, name: String, rule: SmartRule, shared: Bool) async throws -> SmartPlaylistInfo {
        try await api {
            let mine = try await userId()
            return info(try await client.updateSmartPlaylist(id: id, name: name, rule: rule, visibility: shared ? "family" : "private"), mine: mine)
        }
    }

    public func deleteSmartPlaylist(id: String) async throws {
        try await api { try await client.deleteSmartPlaylist(id: id) }
    }

    public func freezeSmartPlaylist(id: String, name: String?) async throws {
        try await api { _ = try await client.freezeSmartPlaylist(id: id, name: name) }
    }
}

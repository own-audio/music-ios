import Foundation

// Identify runs (`modules.identify_library`): the server matches part of the library against
// MusicBrainz in the background and proposes a title, album and MusicBrainz ids for each song;
// the owner accepts or rejects them. Only the server's database changes — never a file.

/// What a run covers: the whole library, or one folder, album, playlist, artist or list of songs.
public struct IdentifyScope: Codable, Sendable, Equatable {
    public var kind: String
    public var id: String?
    public var trackIds: [String]?
    /// How the run is named in lists.
    public var label: String?

    public init(kind: String, id: String? = nil, trackIds: [String]? = nil, label: String? = nil) {
        self.kind = kind
        self.id = id
        self.trackIds = trackIds
        self.label = label
    }

    public static func library(label: String?) -> IdentifyScope { IdentifyScope(kind: "library", label: label) }
}

public struct IdentifyRun: Decodable, Sendable, Equatable, Identifiable {
    public struct Counts: Decodable, Sendable, Equatable {
        public let sure: Int
        public let review: Int
        public let none: Int
        public let pending: Int
        public let accepted: Int
        public let rejected: Int
    }

    public let id: String
    /// `queued`, `running`, `waiting` (the source asked to slow down), `ready`, `failed`,
    /// `cancelled`.
    public let status: String
    public let error: String?
    public let scope: IdentifyScope
    public let tracks: Int
    public let groupsTotal: Int
    public let groupsDone: Int
    public let counts: Counts
    public let createdAt: Date

    /// Still looking songs up.
    public var isActive: Bool { ["queued", "running", "waiting"].contains(status) }
}

/// What a run over a scope would look up, and the most it could cost (0 where it is free).
public struct IdentifyQuote: Decodable, Sendable, Equatable {
    public let tracks: Int
    /// Millionths of the server's currency.
    public let chargeMicro: Int64
}

public struct IdentifyProposal: Decodable, Sendable, Equatable, Identifiable {
    public struct Group: Decodable, Sendable, Equatable {
        public let id: String
        /// `album` or `track`.
        public let kind: String
        public let label: String
    }

    /// The song as the library has it now.
    public struct Song: Decodable, Sendable, Equatable {
        public let id: String
        public let title: String
        public let artist: String?
        public let album: String?
        public let discNumber: Int?
        public let trackNumber: Int?
        public let durationSecs: Int?
    }

    public struct Match: Decodable, Sendable, Equatable {
        public let mbRecordingId: String
        public let title: String
        public let artist: String?
        public let album: String?
        public let albumArtist: String?
        public let mbReleaseId: String?
        public let trackNumber: Int?
        public let discNumber: Int?
        public let year: Int?
        public let lengthMs: Int?
        public let score: Int
    }

    public let id: String
    public let group: Group
    public let track: Song
    /// `sure`, `review` or `none`.
    public let proposalClass: String
    /// Why it is not sure: `incomplete`, `partial`, `layout`, `duplicate`, `ambiguous`,
    /// `album_differs`, `artist_differs`, `weak`, `not_found`, `not_on_release`.
    public let reasons: [String]
    public let proposal: Match?
    /// Keep the file's own album and set only the recording (a compilation's song).
    public let keepAlbum: Bool
    /// `pending`, `accepted` or `rejected`.
    public let decision: String

    enum CodingKeys: String, CodingKey {
        case id, group, track, reasons, proposal, keepAlbum, decision
        case proposalClass = "class"
    }
}

/// An album's editions: every release the source offered, best first.
public struct IdentifyGroup: Decodable, Sendable, Equatable {
    public struct Edition: Decodable, Sendable, Equatable, Identifiable {
        public let index: Int
        public let mbReleaseId: String
        public let title: String
        public let artist: String?
        public let year: Int?
        public let primaryType: String?
        public let secondaryTypes: [String]
        public let status: String?
        public let trackCount: Int
        public let matched: Int
        public let coverArtUrl: String?

        public var id: Int { index }
    }

    public let id: String
    public let kind: String
    public let label: String
    /// The edition the proposals are on; none when the songs matched different releases.
    public let chosen: Int?
    public let editions: [Edition]
}

/// The data of an `identify` event: a run moved on.
public struct IdentifyProgress: Decodable, Sendable, Equatable {
    public let runId: String
    public let status: String
    public let groupsDone: Int
    public let groupsTotal: Int

    public init?(_ event: LiveEvent) {
        guard event.type == "identify",
              let progress = try? JSONDecoder.ownAudio.decode(IdentifyProgress.self, from: Data(event.data.utf8))
        else { return nil }
        self = progress
    }
}

extension OwnAudioClient {
    /// The optional parts this server offers (`modules` of its discovery document), such as
    /// `identify_library` or `billing`, with whether each is on.
    public func modules() async throws -> [String: Bool] {
        struct Discovery: Decodable { let modules: [String: JSONValue]? }
        let discovery: Discovery = try await Self.send(URLRequest(url: host.appending(path: ".well-known/own-audio")), session: session)
        return (discovery.modules ?? [:]).reduce(into: [:]) { out, entry in
            if case .bool(let on) = entry.value { out[entry.key] = on }
        }
    }

    public func identifyQuote(_ scope: IdentifyScope) async throws -> IdentifyQuote {
        struct Body: Encodable { let scope: IdentifyScope }
        return try await call("POST", "identify/quote", body: Body(scope: scope))
    }

    /// Starts a run. `payment_required` (402) when a server that charges for it finds the
    /// credit short.
    public func startIdentify(_ scope: IdentifyScope) async throws -> IdentifyRun {
        struct Body: Encodable { let scope: IdentifyScope }
        return try await call("POST", "identify/runs", body: Body(scope: scope))
    }

    /// The account's runs, newest first.
    public func identifyRuns() async throws -> [IdentifyRun] {
        let page: Page<IdentifyRun> = try await get("identify/runs")
        return page.items
    }

    public func identifyRun(_ id: String) async throws -> IdentifyRun {
        try await get("identify/runs/\(id)")
    }

    /// Stops a run and forgets its proposals; what was accepted stays.
    public func deleteIdentifyRun(_ id: String) async throws {
        try await send("DELETE", "identify/runs/\(id)", body: Optional<Empty>.none)
    }

    /// Undoes every accept of the run; returns how many songs went back.
    public func revertIdentifyRun(_ id: String) async throws -> Int {
        struct Answer: Decodable { let reverted: Int }
        let answer: Answer = try await call("POST", "identify/runs/\(id)/revert", body: Empty())
        return answer.reverted
    }

    /// Accepts every sure match of the run; returns how many.
    public func acceptSureMatches(_ runId: String) async throws -> Int {
        struct Body: Encodable { let `class` = "sure" }
        struct Answer: Decodable { let accepted: Int }
        let answer: Answer = try await call("POST", "identify/runs/\(runId)/accept", body: Body())
        return answer.accepted
    }

    public func identifyProposals(_ runId: String, proposalClass: String? = nil, decision: String? = nil, cursor: String? = nil) async throws -> Page<IdentifyProposal> {
        try await get("identify/runs/\(runId)/proposals", query: ["class": proposalClass, "decision": decision, "cursor": cursor, "limit": "200"])
    }

    @discardableResult
    public func acceptProposal(_ id: String) async throws -> IdentifyProposal {
        try await call("POST", "identify/proposals/\(id)/accept", body: Empty())
    }

    @discardableResult
    public func rejectProposal(_ id: String) async throws -> IdentifyProposal {
        try await call("POST", "identify/proposals/\(id)/reject", body: Empty())
    }

    @discardableResult
    public func setKeepAlbum(_ id: String, _ keep: Bool) async throws -> IdentifyProposal {
        struct Body: Encodable { let keepAlbum: Bool }
        return try await call("PATCH", "identify/proposals/\(id)", body: Body(keepAlbum: keep))
    }

    public func identifyGroup(_ id: String) async throws -> IdentifyGroup {
        try await get("identify/groups/\(id)")
    }

    /// Puts the album's proposals on another of its editions; no new lookup.
    @discardableResult
    public func chooseEdition(group id: String, index: Int) async throws -> IdentifyGroup {
        struct Body: Encodable { let index: Int }
        return try await call("PUT", "identify/groups/\(id)/edition", body: Body(index: index))
    }

    /// Undoes one song's identify (revision 12): it goes back to what its file said.
    public func undoIdentify(track id: String) async throws {
        let _: Empty = try await call("DELETE", "tracks/\(id)/identity", body: Optional<Empty>.none)
    }
}

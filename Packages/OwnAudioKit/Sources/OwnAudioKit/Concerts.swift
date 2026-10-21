import Foundation

// Concerts: a whole concert as one track, with a chapter where each song starts. Servers from
// 1.0.0-beta.35 report `features.track_chapters`.

/// Where a part of a track begins.
public struct TrackChapter: Codable, Sendable, Equatable {
    public let position: Int
    public let title: String
    public let startMs: Int64

    public init(position: Int, title: String, startMs: Int64) {
        self.position = position
        self.title = title
        self.startMs = startMs
    }
}

extension OwnAudioClient {
    /// The yes/no features of `GET /api/v1/server`, such as `track_chapters`.
    public func features() async throws -> [String: Bool] {
        struct Server: Decodable { let features: [String: JSONValue]? }
        let server: Server = try await Self.send(URLRequest(url: host.appending(path: "api/v1/server")), session: session)
        return (server.features ?? [:]).reduce(into: [:]) { out, entry in
            if case .bool(let on) = entry.value { out[entry.key] = on }
        }
    }

    /// A track's chapters in order; empty when its file has none.
    public func trackChapters(id: String) async throws -> [TrackChapter] {
        struct Answer: Decodable { let chapters: [TrackChapter]? }
        let answer: Answer = try await get("tracks/\(id)", query: ["include": nil])
        return answer.chapters ?? []
    }

    /// Replaces a track's chapters (its owner only); they then stay whatever its file says.
    /// An empty list removes them. Answers the list as stored.
    public func setTrackChapters(id: String, _ chapters: [(title: String, startMs: Int64)]) async throws -> [TrackChapter] {
        struct Mark: Encodable { let title: String; let startMs: Int64 }
        struct Body: Encodable { let chapters: [Mark] }
        return try await call("PUT", "tracks/\(id)/chapters", body: Body(chapters: chapters.map { Mark(title: $0.title, startMs: $0.startMs) }))
    }

    /// Where the listener stopped; nil when they never started it.
    public func progress(_ kind: ItemKind, id: String) async throws -> Progress? {
        do {
            return try await get("me/progress/\(kind.rawValue)/\(id)")
        } catch OwnAudioError.problem(let p) where p.status == 404 {
            return nil
        } catch OwnAudioError.http(404) {
            return nil
        }
    }
}

import Foundation
import Testing

@testable import OwnAudioKit

@Suite("Concerts")
struct ConcertsTests {
    private let host = URL(string: "https://music.example.com")!

    private func client(_ answer: @escaping @Sendable (URLRequest) -> MockURLProtocol.StubbedResponse) async -> (OwnAudioClient, MockURLProtocol.StubbedSession) {
        let mock = await MockURLProtocol.makeStubbedSession(answer)
        let tokens = TokenSession(Tokens(accessToken: "a", refreshToken: "r", expiresAt: .distantFuture, scope: ""))
        return (OwnAudioClient(host: host, tokens: tokens, session: mock.urlSession), mock)
    }

    private static func json(_ text: String, status: Int = 200) -> MockURLProtocol.StubbedResponse {
        .init(statusCode: status, body: Data(text.utf8), headers: ["Content-Type": status >= 400 ? "application/problem+json" : "application/json"])
    }

    private static func body(_ request: URLRequest) -> Data {
        request.httpBody ?? request.httpBodyStream.map { stream -> Data in
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            return data
        } ?? Data()
    }

    @Test("a concert's chapters come with the track; an ordinary track has none")
    func chapters() async throws {
        let (client, _) = await client { request in
            request.url?.path.hasSuffix("/t1") == true
                ? Self.json(#"{"id":"t1","chapter_count":2,"chapters":[{"position":1,"title":"Intro","start_ms":0},{"position":2,"title":"Crawling","start_ms":566000}]}"#)
                : Self.json(#"{"id":"t2","chapter_count":0}"#)
        }
        let marks = try await client.trackChapters(id: "t1")
        #expect(marks == [TrackChapter(position: 1, title: "Intro", startMs: 0), TrackChapter(position: 2, title: "Crawling", startMs: 566_000)])
        #expect(try await client.trackChapters(id: "t2").isEmpty)
    }

    @Test("concerts are the albums of kind live")
    func concerts() async throws {
        let (client, log) = await client { _ in Self.json(#"{"items":[],"next":null}"#) }
        _ = try await client.albums(kind: "live")
        let url = try #require(await log.requestLog().first?.url)
        #expect(url.path == "/api/v2/albums")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "kind", value: "live")) == true)
    }

    @Test("edited chapters go as one PUT, snake_case")
    func saveChapters() async throws {
        let (client, log) = await client { _ in Self.json(#"[{"position":1,"title":"Intro","start_ms":0}]"#) }
        let stored = try await client.setTrackChapters(id: "t1", [(title: "Intro", startMs: 0)])
        #expect(stored.map(\.title) == ["Intro"])
        let sent = try #require(await log.requestLog().first)
        #expect(sent.httpMethod == "PUT")
        #expect(sent.url?.path == "/api/v2/tracks/t1/chapters")
        let json = try #require(try JSONSerialization.jsonObject(with: Self.body(sent)) as? [String: Any])
        let first = try #require((json["chapters"] as? [[String: Any]])?.first)
        #expect(first["title"] as? String == "Intro" && first["start_ms"] as? Int == 0)
    }

    @Test("a position never saved is nil, not an error")
    func progress() async throws {
        let (client, _) = await client { request in
            request.url?.path.hasSuffix("/t1") == true
                ? Self.json(#"{"kind":"track","id":"t1","position_ms":2830000,"finished":false,"updated_at":"2026-10-21T19:35:01Z"}"#)
                : Self.json(#"{"type":"urn:own-audio:problem:not_found","title":"Not found","status":404,"code":"not_found"}"#, status: 404)
        }
        #expect(try await client.progress(.track, id: "t1")?.positionMs == 2_830_000)
        #expect(try await client.progress(.track, id: "t2") == nil)
    }

    @Test("features come from the server endpoint")
    func features() async throws {
        let (client, log) = await client { _ in Self.json(#"{"features":{"track_chapters":true,"auth":{"google":true},"uploaded_podcasts":false}}"#) }
        let features = try await client.features()
        #expect(features["track_chapters"] == true && features["uploaded_podcasts"] == false && features["auth"] == nil)
        #expect(await log.requestLog().first?.url?.path == "/api/v1/server")
    }
}

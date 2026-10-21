import Foundation
import OwnAudioKit
import SubsonicKit
import Testing

@testable import MusicLibrary

@Suite("Concerts through the own.audio source")
struct ConcertSourceTests {
    private let host = URL(string: "https://music.example.com")!

    private func source(_ session: URLSession) -> OwnAudioSource {
        OwnAudioSource(
            username: "me@example.com", subsonic: nil,
            client: OwnAudioClient(host: host, tokens: TokenSession(Tokens(accessToken: "a", refreshToken: "r", expiresAt: .distantFuture, scope: "")), session: session)
        )
    }

    private static func json(_ text: String, status: Int = 200) -> MockURLProtocol.StubbedResponse {
        .init(statusCode: status, body: Data(text.utf8), headers: ["Content-Type": status >= 400 ? "application/problem+json" : "application/json"])
    }

    private static let concertAlbum = #"{"id":"al","title":"Rock in Rio Lisboa","credits":[],"release_group_id":"rg","release_date":"2026","is_compilation":false,"track_count":1,"duration_ms":5865000,"disc_count":1,"image":null,"created_at":"2026-10-21T19:35:00Z"}"#

    @Test("a server with track_chapters has concerts; the list is its live albums")
    func concerts() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { request in
            switch request.url?.path {
            case "/api/v1/server": Self.json(#"{"features":{"track_chapters":true}}"#)
            default: Self.json(#"{"items":[\#(Self.concertAlbum)],"next":null}"#)
            }
        }
        let source = source(mock.urlSession)
        #expect(await source.supportsConcerts())
        let concerts = try await source.concerts()
        #expect(concerts.map(\.name) == ["Rock in Rio Lisboa"])
        let listing = await mock.requestLog().first { $0.url?.path == "/api/v2/albums" }?.url
        #expect(listing?.query?.contains("kind=live") == true)
    }

    @Test("an older server has none")
    func olderServer() async {
        let mock = await MockURLProtocol.makeStubbedSession { _ in Self.json(#"{"features":{"subsonic":true}}"#) }
        #expect(await source(mock.urlSession).supportsConcerts() == false)
    }

    @Test("chapters in seconds, saved in milliseconds and in order")
    func chapters() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { request in
            request.httpMethod == "PUT"
                ? Self.json(#"[{"position":1,"title":"Intro","start_ms":0},{"position":2,"title":"Crawling","start_ms":566500}]"#)
                : Self.json(#"{"id":"t1","chapters":[{"position":1,"title":"Intro","start_ms":0},{"position":2,"title":"Crawling","start_ms":566500}]}"#)
        }
        let source = source(mock.urlSession)
        #expect(try await source.chapters(songId: "t1") == [SongChapter(title: "Intro", startSecs: 0), SongChapter(title: "Crawling", startSecs: 566.5)])
        _ = try await source.saveChapters(songId: "t1", [SongChapter(title: "Crawling", startSecs: 566.5), SongChapter(title: "Intro", startSecs: 0)])
        let put = try #require(await mock.requestLog().first { $0.httpMethod == "PUT" })
        let body = put.httpBody ?? put.httpBodyStream.map { stream -> Data in
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            return data
        } ?? Data()
        let sent = try #require((try JSONSerialization.jsonObject(with: body) as? [String: Any])?["chapters"] as? [[String: Any]])
        #expect(sent.map { $0["start_ms"] as? Int } == [0, 566_500])
    }

    @Test("someone else's concert: not allowed")
    func notTheOwner() async {
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            Self.json(#"{"type":"urn:own-audio:problem:forbidden","title":"Forbidden","status":403,"code":"forbidden"}"#, status: 403)
        }
        await #expect(throws: SourceError.notAllowed) {
            try await source(mock.urlSession).saveChapters(songId: "t1", [])
        }
    }

    @Test("the saved position resumes; a finished one does not")
    func position() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { request in
            request.url?.path.hasSuffix("/t1") == true
                ? Self.json(#"{"kind":"track","id":"t1","position_ms":2830000,"finished":false,"updated_at":"2026-10-21T19:35:01Z"}"#)
                : Self.json(#"{"kind":"track","id":"t2","position_ms":5865000,"finished":true,"updated_at":"2026-10-21T19:35:01Z"}"#)
        }
        let source = source(mock.urlSession)
        #expect(try await source.savedPosition(songId: "t1") == 2830)
        #expect(try await source.savedPosition(songId: "t2") == nil)
    }

    @Test("a song knows it is a concert from its chapter count")
    func songIsAConcert() throws {
        let track = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"id":"t1","title":"Rock in Rio Lisboa","album_id":null,"recording_id":null,"credits":[],"genre_ids":[],"disc_number":null,"track_number":null,"duration_ms":5865000,"visibility":"family","owner_id":"u","content_type":"audio/mp4","size_bytes":94000000,"image":null,"chapter_count":27,"created_at":"2026-10-21T19:35:00Z","updated_at":"2026-10-21T19:35:00Z"}"#.utf8))
        let (_, _, songs) = OwnAudioSource.library(FeedState(cursor: "c", records: ["track": ["t1": track]]))
        let song = try #require(songs.first)
        #expect(song.chapterCount == 27 && song.isConcert)
    }

    @Test("other servers have no concerts")
    func subsonicHasNone() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in Self.json("{}") }
        let subsonic = SubsonicSource(client: SubsonicClient(host: host, username: "u", password: "p", session: mock.urlSession))
        #expect(await subsonic.supportsConcerts() == false)
        #expect(try await subsonic.chapters(songId: "x").isEmpty)
        #expect(await mock.requestLog().isEmpty, "asking costs no request")
    }
}

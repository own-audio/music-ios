import Foundation
import Testing

@testable import OwnAudioKit

@Suite("Identify")
struct IdentifyTests {
    private let host = URL(string: "https://music.example.com")!

    private func client(_ mock: MockURLProtocol.StubbedSession) -> OwnAudioClient {
        OwnAudioClient(host: host, tokens: TokenSession(Tokens(accessToken: "a", refreshToken: "r", expiresAt: .distantFuture, scope: "")), session: mock.urlSession)
    }

    private func json(_ text: String, status: Int = 200) -> MockURLProtocol.StubbedResponse {
        .init(statusCode: status, body: Data(text.utf8), headers: ["Content-Type": "application/json"])
    }

    private func body(_ request: URLRequest) -> String {
        let data = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            return data
        } ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    @Test("a run starts with its scope as snake_case JSON and decodes")
    func start() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            json(#"{"id":"r1","status":"queued","error":null,"scope":{"kind":"tracks","id":null,"label":"Two"},"tracks":0,"groups_total":0,"groups_done":0,"counts":{"sure":0,"review":0,"none":0,"pending":0,"accepted":0,"rejected":0},"created_at":"2026-10-12T05:01:38.047961Z","started_at":null,"finished_at":null}"#, status: 202)
        }
        let run = try await client(mock).startIdentify(IdentifyScope(kind: "tracks", trackIds: ["t1", "t2"], label: "Two"))
        #expect(run.isActive)
        let sent = await mock.requestLog().first!
        #expect(sent.url?.path == "/api/v2/identify/runs")
        #expect(body(sent).contains(#""track_ids":["t1","t2"]"#))
    }

    @Test("a proposal decodes, its class and match included")
    func proposals() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { request in
            #expect(request.url?.query?.contains("class=review") == true)
            return json(#"{"items":[{"id":"p1","group":{"id":"g1","kind":"album","label":"Load — Metallica"},"track":{"id":"t1","title":"X 4","artist":"Metallica","album":"Load","disc_number":null,"track_number":2,"duration_secs":140},"class":"review","reasons":["artist_differs","album_differs"],"proposal":{"mb_recording_id":"m1","title":"X 4","artist":"Guy Boulanger","album":"Load","album_artist":null,"mb_release_id":"rel1","track_number":7,"disc_number":1,"year":1978,"length_ms":140000,"score":91},"keep_album":true,"decision":"pending"}]}"#)
        }
        let page = try await client(mock).identifyProposals("r1", proposalClass: "review", decision: "pending")
        let p = try #require(page.items.first)
        #expect(p.proposalClass == "review")
        #expect(p.reasons == ["artist_differs", "album_differs"])
        #expect(p.proposal?.mbRecordingId == "m1")
        #expect(p.keepAlbum)
        #expect(page.next == nil)
    }

    @Test("accepting the sure matches says which class")
    func acceptSure() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in json(#"{"accepted":16}"#) }
        #expect(try await client(mock).acceptSureMatches("r1") == 16)
        let sent = await mock.requestLog().first!
        #expect(body(sent) == #"{"class":"sure"}"#)
    }

    @Test("a short credit is a problem with its code")
    func paymentRequired() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            json(#"{"type":"urn:own-audio:problem:payment_required","title":"Payment Required","status":402,"code":"payment_required","detail":"identifying these tracks can cost up to $0.032"}"#, status: 402)
        }
        await #expect(throws: OwnAudioError.self) { try await client(mock).startIdentify(.library(label: nil)) }
        do {
            _ = try await client(mock).startIdentify(.library(label: nil))
        } catch OwnAudioError.problem(let p) {
            #expect(p.code == "payment_required")
        }
    }

    @Test("modules are read from the discovery document")
    func modules() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { request in
            #expect(request.url?.path == "/.well-known/own-audio")
            return json(#"{"modules":{"identify_library":true,"billing":false,"auth":{"google":true}}}"#)
        }
        let modules = try await client(mock).modules()
        #expect(modules["identify_library"] == true)
        #expect(modules["billing"] == false)
        #expect(modules["auth"] == nil)
    }

    @Test("music folders come from /api/v1, other kinds left out")
    func folders() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { request in
            #expect(request.url?.path == "/api/v1/library/folders")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer a")
            return json(#"{"folders":[{"id":"f1","path":"/music/A","kind":"music"},{"id":"f2","path":"/books","kind":"books"}],"scanning":false}"#)
        }
        let folders = try await client(mock).musicFolders()
        #expect(folders.map(\.id) == ["f1"])
    }

    @Test("a search in the owner's words sends only what was typed and decodes candidates")
    func search() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            json(#"{"items":[{"mb_recording_id":"m1","title":"Yesterday","artist":"The Beatles","mb_artist_id":null,"album":"Help!","mb_release_id":"rel1","duration_ms":125000,"genre":null,"track_number":13,"year":1965,"cover_art_url":null,"score":100}]}"#)
        }
        let found = try await client(mock).searchRecordings(track: "t1", RecordingSearch(title: "Yesterday", artist: "The Beatles"))
        #expect(found.first?.album == "Help!")
        #expect(found.first?.id == "m1/rel1")
        let sent = await mock.requestLog().first!
        #expect(sent.url?.path == "/api/v2/tracks/t1/identity/search")
        #expect(!body(sent).contains("album"))
    }

    @Test("choosing a recording for a proposal sends the link and whether to accept")
    func choose() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            json(#"{"id":"p1","group":{"id":"g1","kind":"track","label":"Track 02"},"track":{"id":"t1","title":"Track 02","artist":null,"album":null,"disc_number":null,"track_number":2,"duration_secs":125},"class":"review","reasons":["chosen"],"proposal":{"mb_recording_id":"m1","title":"Yesterday","artist":"The Beatles","album":"Help!","album_artist":null,"mb_release_id":"rel1","track_number":13,"disc_number":null,"year":null,"length_ms":null,"score":100},"keep_album":false,"decision":"accepted","chosen_by_owner":true,"alternatives":3}"#)
        }
        let p = try await client(mock).chooseRecording(proposal: "p1", recording: "https://musicbrainz.org/recording/m1", accept: true)
        #expect(p.chosenByOwner == true)
        #expect(p.alternatives == 3)
        let sent = await mock.requestLog().first!
        #expect(sent.httpMethod == "PUT")
        #expect(sent.url?.path == "/api/v2/identify/proposals/p1/recording")
        #expect(body(sent).contains(#""accept":true"#))
    }

    @Test("the server's revision comes from /api/v1/server")
    func revision() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { request in
            #expect(request.url?.path == "/api/v1/server")
            return json(#"{"api":{"version":1,"revision":13},"edition":"foss"}"#)
        }
        #expect(try await client(mock).apiRevision() == 13)
    }

    @Test("an identify event reads as progress; others do not")
    func progress() {
        let event = LiveEvent(type: "identify", id: nil, data: #"{"groups_done":5,"groups_total":5,"run_id":"r1","status":"ready"}"#)
        #expect(IdentifyProgress(event)?.status == "ready")
        #expect(IdentifyProgress(LiveEvent(type: "library", id: "9", data: #"{"seq":9}"#)) == nil)
    }
}

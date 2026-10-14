import Foundation
import OwnAudioKit
import SubsonicKit
import Testing

@testable import MusicLibrary

@Suite("own.audio change feed")
struct OwnAudioFeedTests {
    private let host = URL(string: "https://music.example.com")!

    private func value(_ json: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    private func state() -> FeedState {
        FeedState(cursor: "c0", records: [
            "contributor": [
                "band": value(#"{"id":"band","name":"The Band","sort_name":null,"kind":"group","musicbrainz_artist_id":null,"image":"https://music.example.com/api/v2/images/o1?e=1&s=x"}"#),
                "guest": value(#"{"id":"guest","name":"A Guest","sort_name":null,"kind":"person","musicbrainz_artist_id":null,"image":null}"#),
                "reader": value(#"{"id":"reader","name":"A Narrator","sort_name":null,"kind":"person","musicbrainz_artist_id":null,"image":null}"#),
            ],
            "album": [
                "al": value(#"{"id":"al","title":"First Album","credits":[{"contributor_id":"band","role":"artist","position":0,"join_phrase":""}],"release_group_id":"rg","release_date":"2001-05-01","is_compilation":false,"track_count":2,"duration_ms":400000,"disc_count":1,"image":"https://x","created_at":"2026-10-11T12:00:00Z"}"#),
            ],
            "genre": ["g": value(#"{"id":"g","name":"Rock"}"#)],
            "track": [
                "t1": value(#"{"id":"t1","title":"Song One","album_id":"al","recording_id":null,"credits":[{"contributor_id":"band","role":"artist","position":0,"join_phrase":" feat. "},{"contributor_id":"guest","role":"featured","position":1,"join_phrase":""}],"genre_ids":["g"],"disc_number":1,"track_number":1,"duration_ms":200000,"visibility":"family","owner_id":"u","content_type":"audio/flac","size_bytes":20000000,"image":null,"created_at":"2026-10-11T12:00:00Z","updated_at":"2026-10-11T12:00:00Z"}"#),
            ],
            "favourite.track": ["t1": value(#"{"kind":"track","id":"t1","created_at":"2026-10-11T12:00:00Z"}"#)],
            "rating.album": ["al": value(#"{"kind":"album","id":"al","rating":4,"updated_at":"2026-10-11T12:00:00Z"}"#)],
        ])
    }

    @Test("the API's records become the app's songs, albums and artists")
    func mapping() {
        let (artists, albums, songs) = OwnAudioSource.library(state())
        let song = try! #require(songs.first)
        #expect(song.artist == "The Band feat. A Guest")
        #expect(song.artistId == "band")
        #expect(song.album == "First Album")
        #expect(song.genre == "Rock")
        #expect(song.duration == 200)
        #expect(song.suffix == "flac")
        #expect(song.coverArt == "al", "no cover of its own: the album's")
        #expect(song.isFavorite)
        let album = try! #require(albums.first)
        #expect(album.artist == "The Band" && album.year == 2001 && album.rating == 4 && album.coverArt == "al")
        #expect(Set(artists.map(\.id)) == ["band"], "a featured guest on a track, and a narrator, are not artists")
        #expect(artists.first?.coverArt == "band", "a picture by id, like a cover: its link runs out")
        #expect(artists.first?.imageURL == nil)
    }

    @Test("changes: upserts and deletes applied, other kinds left out, the cursor moved on")
    func applyingChanges() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { request in
            #expect(request.url?.path == "/api/v2/sync/changes")
            let body = #"{"changes":[{"kind":"track","id":"t1","op":"upsert","record":{"id":"t1","title":"Song One (Live)","album_id":"al","recording_id":null,"credits":[],"genre_ids":[],"disc_number":1,"track_number":1,"duration_ms":200000,"visibility":"family","owner_id":"u","content_type":"audio/mpeg","size_bytes":1,"image":null,"created_at":"2026-10-11T12:00:00Z","updated_at":"2026-10-11T13:00:00Z"}},{"kind":"favourite.track","id":"t1","op":"delete"},{"kind":"book","id":"b1","op":"upsert","record":{"id":"b1"}}],"cursor":"c1","has_more":false,"reset":false}"#
            return .init(statusCode: 200, body: Data(body.utf8), headers: ["Content-Type": "application/json"])
        }
        let source = OwnAudioSource(
            username: "me@example.com", subsonic: SubsonicSource(client: SubsonicClient(host: host, username: "u", password: "k", session: mock.urlSession)),
            client: OwnAudioClient(host: host, tokens: TokenSession(Tokens(accessToken: "a", refreshToken: "r", expiresAt: .distantFuture, scope: "")), session: mock.urlSession)
        )
        let result = try await source.syncCatalogue(state())
        #expect(result.state.cursor == "c1")
        #expect(result.songs.first?.title == "Song One (Live)")
        #expect(result.songs.first?.isFavorite == false)
        #expect(result.state.records["book"] == nil)
    }

    @Test("an expired cursor means a fresh snapshot")
    func expiredCursor() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { request in
            if request.url?.path == "/api/v2/sync/changes" {
                let problem = #"{"type":"urn:own-audio:problem:sync_cursor_expired","title":"Gone","status":410,"code":"sync_cursor_expired"}"#
                return .init(statusCode: 410, body: Data(problem.utf8), headers: ["Content-Type": "application/problem+json"])
            }
            let lines = [#"{"type":"begin","cursor":"s1"}"#,
                         #"{"type":"record","kind":"genre","id":"g2","record":{"id":"g2","name":"Jazz"}}"#,
                         #"{"type":"end","cursor":"s1"}"#].joined(separator: "\n") + "\n"
            return .init(statusCode: 200, body: Data(lines.utf8), headers: ["Content-Type": "application/x-ndjson"])
        }
        let source = OwnAudioSource(
            username: "me@example.com", subsonic: SubsonicSource(client: SubsonicClient(host: host, username: "u", password: "k", session: mock.urlSession)),
            client: OwnAudioClient(host: host, tokens: TokenSession(Tokens(accessToken: "a", refreshToken: "r", expiresAt: .distantFuture, scope: "")), session: mock.urlSession)
        )
        let result = try await source.syncCatalogue(state())
        #expect(result.state.cursor == "s1")
        #expect(result.state.records["genre"]?["g2"] != nil)
        #expect(result.state.records["track"] == nil, "a snapshot replaces what was kept")
    }
}

@Suite("own.audio offline edits and live updates")
struct OwnAudioPushTests {
    private let host = URL(string: "https://music.example.com")!

    private func source(_ session: URLSession, signedIn: Bool = true) -> OwnAudioSource {
        OwnAudioSource(
            username: "me@example.com", subsonic: SubsonicSource(client: SubsonicClient(host: host, username: "u", password: "k", session: session)),
            client: OwnAudioClient(host: host, tokens: TokenSession(signedIn ? Tokens(accessToken: "a", refreshToken: "r", expiresAt: .distantFuture, scope: "") : nil), session: session)
        )
    }

    @Test("edits become the API's changes: kinds mapped, a play with its length")
    func mapping() {
        let at = Date(timeIntervalSince1970: 1_791_000_000)
        let rating = OwnAudioSource.change(.init(clientId: "c1", itemId: "al", change: .rating(.album, 4), madeAt: at))
        #expect(rating.op == "rate" && rating.kind == .album && rating.rating == 4 && rating.at == at)
        let artist = OwnAudioSource.change(.init(clientId: "c2", itemId: "ar", change: .favorite(.artist, false), madeAt: at))
        #expect(artist.op == "unfavourite" && artist.kind == .contributor)
        let play = OwnAudioSource.change(.init(clientId: "c3", itemId: "t1", change: .played(startedAt: at, heardSecs: 120.5), madeAt: at.addingTimeInterval(121)))
        #expect(play.op == "play" && play.kind == .track && play.listenedMs == 120_500)
        #expect(play.startedAt == at && play.endedAt == at.addingTimeInterval(121) && play.clientId == "c3")
    }

    @Test("more than 500 go in several requests")
    func batches() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            .init(statusCode: 200, body: Data("[]".utf8), headers: ["Content-Type": "application/json"])
        }
        let edits = (0..<1001).map { OfflineEdit(clientId: "c\($0)", itemId: "t\($0)", change: .favorite(.song, true), madeAt: Date()) }
        try await source(mock.urlSession).push(edits)
        #expect(await mock.requestLog().count == 3)
    }

    @Test("an own.audio server signed in the old way sends them one at a time")
    func notSignedIn() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in .init(statusCode: 500, body: Data()) }
        await #expect(throws: SourceError.unsupported) {
            try await source(mock.urlSession, signedIn: false).push([.init(clientId: "c", itemId: "t", change: .favorite(.song, true), madeAt: Date())])
        }
        #expect(await mock.requestLog().isEmpty)
    }

    @Test("only library events are passed on")
    func liveUpdates() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            .init(statusCode: 200, body: Data("event: library\nid: 1\ndata: {}\n\nevent: other\ndata: x\n\nevent: library\nid: 2\ndata: {}\n\n".utf8),
                  headers: ["Content-Type": "text/event-stream"])
        }
        var count = 0
        for try await _ in source(mock.urlSession).libraryChanges() { count += 1 }
        #expect(count == 2)
    }
}

@Suite("own.audio sign-in kept in the Keychain")
struct OwnAudioAuthTests {
    @Test("an own.audio server saved before tokens still loads, and the new kind round-trips")
    func records() throws {
        let host = URL(string: "https://music.example.com")!
        let old = ServerRecord(displayName: "old", kind: .ownAudio, host: host, auth: .subsonic(username: "a@example.com", password: "key"))
        let reloaded = try JSONDecoder().decode(ServerRecord.self, from: JSONEncoder().encode(old))
        #expect(reloaded.auth == .subsonic(username: "a@example.com", password: "key"))
        let tokens = Tokens(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 2_000_000_000), scope: "library:read")
        let new = ServerRecord(displayName: "new", kind: .ownAudio, host: host, auth: .ownAudio(username: "a@example.com", key: "key", tokens: tokens))
        let back = try JSONDecoder().decode(ServerRecord.self, from: JSONEncoder().encode(new))
        #expect(back.auth == new.auth)
        #expect(back.auth.username == "a@example.com")
    }

    @Test("one token session per server, however many sources are made")
    func oneSessionPerServer() async {
        let sessions = OwnAudioSessions(store: nil)
        let id = UUID()
        let first = sessions.session(for: id, tokens: nil)
        let second = sessions.session(for: id, tokens: Tokens(accessToken: "x", refreshToken: "y", expiresAt: .distantFuture, scope: ""))
        #expect(first === second)
        sessions.forget(id)
        #expect(sessions.session(for: id, tokens: nil) !== first)
    }
}


@Suite("own.audio through its own API (M8d)")
struct OwnAudioAPITests {
    private let host = URL(string: "https://music.example.com")!

    private func value(_ json: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    private func source(_ session: URLSession, listener: ListenerState = ListenerState(), offline: OfflineSwitch? = nil, cache: AnswerCache? = nil, signedIn: Bool = true, key: Bool = true) -> OwnAudioSource {
        OwnAudioSource(
            username: "me@example.com", subsonic: key ? SubsonicSource(client: SubsonicClient(host: host, username: "me@example.com", password: "k", session: session)) : nil,
            client: OwnAudioClient(
                host: host, tokens: TokenSession(signedIn ? Tokens(accessToken: "a", refreshToken: "r", expiresAt: .distantFuture, scope: "") : nil),
                session: session, cache: cache, isOffline: { offline?.isOn == true }
            ),
            listener: listener
        )
    }

    private func json(_ text: String) -> MockURLProtocol.StubbedResponse {
        .init(statusCode: 200, body: Data(text.utf8), headers: ["Content-Type": "application/json"])
    }

    private let track = #"{"id":"t1","title":"Song One","album_id":"al","recording_id":null,"credits":[{"contributor_id":"band","role":"artist","position":0,"join_phrase":""}],"genre_ids":[],"disc_number":1,"track_number":1,"duration_ms":200000,"visibility":"family","owner_id":"u","content_type":"audio/flac","size_bytes":1,"image":null,"created_at":"2026-10-11T12:00:00Z","updated_at":"2026-10-11T12:00:00Z"}"#
    private let album = #"{"id":"al","title":"First Album","credits":[{"contributor_id":"band","role":"artist","position":0,"join_phrase":""}],"release_group_id":null,"release_date":"2001","is_compilation":false,"track_count":1,"duration_ms":200000,"disc_count":1,"image":null,"created_at":"2026-10-11T12:00:00Z"}"#
    private let band = #"{"id":"band","name":"The Band","sort_name":null,"kind":"group","musicbrainz_artist_id":null,"image":null}"#

    @Test("favorites and ratings come from the change feed")
    func listenerFromFeed() {
        let feed = FeedState(cursor: "c", records: [
            "favourite.track": ["t1": value(#"{"kind":"track","id":"t1"}"#)],
            "favourite.contributor": ["band": value(#"{"kind":"contributor","id":"band"}"#)],
            "rating.album": ["al": value(#"{"kind":"album","id":"al","rating":4}"#)],
        ])
        let state = ListenerState()
        state.update(from: feed)
        #expect(state.current.favourites == ["t1", "band"])
        #expect(state.current.ratings == ["al": 4])
    }

    @Test("search: songs keep their hearts, an album found by title gets its artist's name")
    func search() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { [track, album, band] request in
            switch request.url?.path {
            case "/api/v2/search": return .init(statusCode: 200, body: Data(#"{"artists":[],"albums":[\#(album)],"tracks":[\#(track)],"included":{"albums":[\#(album)]}}"#.utf8), headers: ["Content-Type": "application/json"])
            case "/api/v2/contributors/band": return .init(statusCode: 200, body: Data(band.utf8), headers: ["Content-Type": "application/json"])
            default: return .init(statusCode: 404, body: Data())
            }
        }
        let listener = ListenerState()
        listener.setFavourite("t1", true)
        let result = try await source(mock.urlSession, listener: listener).search("song")
        #expect(result.songs.first?.isFavorite == true)
        #expect(result.songs.first?.album == "First Album")
        #expect(result.albums.first?.artist == "The Band")
    }

    @Test("a playlist: whose it is by owner, and each song with its entry id")
    func playlist() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { [track] request in
            switch request.url?.path {
            case "/api/v2/me": return .init(statusCode: 200, body: Data(#"{"id":"u","email":"me@example.com","display_name":"Me","family":{"id":"f","role":"admin","can_upload":true}}"#.utf8), headers: ["Content-Type": "application/json"])
            case "/api/v2/playlists": return .init(statusCode: 200, body: Data(#"{"items":[{"id":"p1","name":"Mine","description":null,"visibility":"private","owner_id":"u","track_count":1,"duration_ms":200000,"image":null,"created_at":"2026-10-11T12:00:00Z","updated_at":"2026-10-11T12:00:00Z"},{"id":"p2","name":"Theirs","description":"x","visibility":"family","owner_id":"other","track_count":0,"duration_ms":0,"image":null,"created_at":"2026-10-11T12:00:00Z","updated_at":"2026-10-11T12:00:00Z"}]}"#.utf8), headers: ["Content-Type": "application/json"])
            case "/api/v2/playlists/p1": return .init(statusCode: 200, body: Data(#"{"id":"p1","name":"Mine","description":null,"visibility":"private","owner_id":"u","track_count":1,"duration_ms":200000,"image":null,"created_at":"2026-10-11T12:00:00Z","updated_at":"2026-10-11T12:00:00Z"}"#.utf8), headers: ["Content-Type": "application/json"])
            case "/api/v2/playlists/p1/entries": return .init(statusCode: 200, body: Data(#"{"items":[{"id":"e1","position":1,"added_at":"2026-10-11T12:00:00Z","track":\#(track)}]}"#.utf8), headers: ["Content-Type": "application/json"])
            default: return .init(statusCode: 404, body: Data())
            }
        }
        let src = source(mock.urlSession)
        let lists = try await src.playlists()
        #expect(lists.first { $0.id == "p1" }?.owner == "me@example.com", "the account's own: its username, so the app lets it edit")
        #expect(lists.first { $0.id == "p2" }?.owner == "other")
        let (record, songs) = try await src.playlist(id: "p1")
        #expect(record.songCount == 1 && songs.first?.playlistEntryId == "e1")
    }

    @Test("offline, or with the API's sign-in gone, the Subsonic API answers")
    func fallbacks() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            .init(statusCode: 200, body: Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1","playlists":{"playlist":[]}}}"#.utf8), headers: ["Content-Type": "application/json"])
        }
        let offline = OfflineSwitch()
        offline.isOn = true
        _ = try? await source(mock.urlSession, offline: offline).playlists()
        _ = try? await source(mock.urlSession, signedIn: false).playlists()
        let paths = await mock.requestLog().compactMap(\.url?.path)
        #expect(!paths.isEmpty && paths.allSatisfy { $0.hasPrefix("/rest/") }, "\(paths)")
    }

    @Test("no instant mix for own.audio")
    func noInstantMix() async {
        let mock = await MockURLProtocol.makeStubbedSession { _ in .init(statusCode: 404, body: Data()) }
        #expect(!source(mock.urlSession).capabilities.contains(.instantMix))
    }

    private static let me = #"{"id":"u","email":"me@example.com","display_name":"Me","family":{"id":"f","role":"admin","can_upload":true}}"#

    private func page(_ items: [String], next: String? = nil, included: String? = nil) -> MockURLProtocol.StubbedResponse {
        let nextJSON = next.map { "\"\($0)\"" } ?? "null"
        return json(#"{"items":[\#(items.joined(separator: ","))],"next":\#(nextJSON)\#(included.map { #","included":\#($0)"# } ?? "")}"#)
    }

    private func album(_ id: String, title: String, image: String? = nil) -> String {
        let imageJSON = image.map { "\"\($0)\"" } ?? "null"
        return #"{"id":"\#(id)","title":"\#(title)","credits":[{"contributor_id":"band","role":"artist","position":0,"join_phrase":""}],"release_group_id":null,"release_date":"2001","is_compilation":false,"track_count":1,"duration_ms":200000,"disc_count":1,"image":\#(imageJSON),"created_at":"2026-10-11T12:00:00Z"}"#
    }

    @Test("albums by name: the app's offsets over the API's cursors, one request per page")
    func pagingByOffset() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { [self] request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let cursor = items.first { $0.name == "cursor" }?.value
            let limit = items.first { $0.name == "limit" }?.value
            switch (cursor, limit) {
            case (nil, "2"): return page([album("a", title: "A"), album("b", title: "B")], next: "after-b", included: "{\"contributors\":[\(band)]}")
            case ("after-b", "2"): return page([album("c", title: "C")], next: nil)
            default: return .init(statusCode: 400, body: Data())
            }
        }
        let src = source(mock.urlSession)
        let first = try await src.albums(.name, limit: 2, offset: 0)
        #expect(first.map(\.id) == ["a", "b"] && first.first?.artist == "The Band")
        let second = try await src.albums(.name, limit: 2, offset: 2)
        #expect(second.map(\.id) == ["c"])
        #expect(try await src.albums(.name, limit: 2, offset: 4).isEmpty, "past the end: no request")
        #expect(await mock.requestLog().count == 2)
    }

    @Test("a jump to an offset not reached yet skips there from the start")
    func pagingJump() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { [self] request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            switch (items.first { $0.name == "cursor" }?.value, items.first { $0.name == "limit" }?.value) {
            case (nil, "3"): return page([album("a", title: "A"), album("b", title: "B"), album("c", title: "C")], next: "after-c")
            case ("after-c", "2"): return page([album("d", title: "D"), album("e", title: "E")], next: "after-e")
            default: return .init(statusCode: 400, body: Data())
            }
        }
        let albums = try await source(mock.urlSession).albums(.name, limit: 2, offset: 3)
        #expect(albums.map(\.id) == ["d", "e"])
    }

    @Test("a cover: the record's signed link at the nearest size made; an unknown id is read again")
    func covers() async throws {
        let future = Int(Date().timeIntervalSince1970) + 7 * 86_400
        let link = "https://music.example.com/api/v2/images/o9?e=\(future)&s=sig"
        let mock = await MockURLProtocol.makeStubbedSession { [self] request in
            switch request.url?.path {
            case "/api/v2/albums/t9": return .init(statusCode: 404, body: Data(#"{"status":404,"code":"not_found","title":"Not Found"}"#.utf8), headers: ["Content-Type": "application/problem+json"])
            case "/api/v2/tracks/t9": return json(track.replacingOccurrences(of: #""id":"t1""#, with: #""id":"t9""#).replacingOccurrences(of: #""image":null"#, with: "\"image\":\"\(link)\""))
            default: return .init(statusCode: 404, body: Data())
            }
        }
        let src = source(mock.urlSession)
        let url = try await src.coverURL(id: "t9", size: 300)
        #expect(url.absoluteString == link + "&w=512")
        _ = try await src.coverURL(id: "t9", size: 100)
        #expect(await mock.requestLog().count == 2, "known now: no third request")
        #expect(src.records.kind(of: "t9") == .track)
    }

    @Test("a link about to run out is not used")
    func expiredCover() {
        let index = RecordIndex()
        index.learn("x", .album, image: "https://h/api/v2/images/o?e=\(Int(Date().timeIntervalSince1970) + 60)&s=s")
        #expect(index.image(of: "x") == nil)
        index.learn("y", .album, image: "https://h/api/v2/images/o?e=\(Int(Date().timeIntervalSince1970) + 86_400)&s=s")
        #expect(index.image(of: "y") != nil)
    }

    @Test("a stream: playback-info says what the player can decode and the bitrate wanted")
    func stream() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { [self] request in
            guard request.url?.path == "/api/v2/playback-info" else { return .init(statusCode: 404, body: Data()) }
            return json(#"{"decision":"transcode","url":"https://music.example.com/api/v2/stream?i=track:t1&s=x","expires_at":"2030-01-01T00:00:00Z","content_type":"audio/aac","bitrate_kbps":128,"reasons":["over_bitrate_limit"]}"#)
        }
        let url = try await source(mock.urlSession).streamURL(songId: "t1", maxBitrate: 128_000)
        #expect(url.path == "/api/v2/stream")
        let request = try #require(await mock.requestLog().first)
        let body = try JSONSerialization.jsonObject(with: Self.body(of: request)) as? [String: Any]
        let capabilities = body?["capabilities"] as? [String: Any]
        #expect(body?["kind"] as? String == "track" && body?["id"] as? String == "t1")
        #expect(capabilities?["max_bitrate_kbps"] as? Int == 128)
        #expect((capabilities?["direct"] as? [String])?.contains("audio/flac") == true)
        #expect((capabilities?["direct"] as? [String])?.contains("audio/ogg") == false)
    }

    @Test("an album seen once opens offline from what the API saved, with no request")
    func savedAnswers() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { [self] request in
            switch request.url?.path {
            case "/api/v2/albums/al": return json(album("al", title: "First Album").dropLast() + #","included":{"contributors":[\#(band)]}}"#)
            case "/api/v2/tracks": return page([track], included: "{\"albums\":[\(album("al", title: "First Album"))],\"contributors\":[\(band)]}")
            default: return .init(statusCode: 404, body: Data())
            }
        }
        let cache = MemoryAnswers()
        let offline = OfflineSwitch()
        let online = try await source(mock.urlSession, offline: offline, cache: cache).album(id: "al")
        offline.isOn = true
        let saved = try await source(mock.urlSession, offline: offline, cache: cache).album(id: "al")
        #expect(saved.album.name == online.album.name && saved.songs.map(\.id) == ["t1"])
        #expect(await mock.requestLog().count == 2, "both requests online, none offline")
    }

    @Test("a rating goes to the kind the record was shown as")
    func ratingKind() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in .init(statusCode: 204, body: Data()) }
        let src = source(mock.urlSession)
        src.records.learn("al", .album, image: nil)
        try await src.setRating(id: "al", rating: 4)
        #expect(await mock.requestLog().first?.url?.path == "/api/v2/me/ratings/album/al")
    }

    @Test("a play counted goes to the API, with how long it was heard")
    func play() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { [self] _ in json(#"[{"client_id":"x","status":"ok"}]"#) }
        try await source(mock.urlSession).reportPlayed(songId: "t1", at: Date().addingTimeInterval(-120))
        let request = try #require(await mock.requestLog().first)
        #expect(request.url?.path == "/api/v2/me/plays")
        let body = try JSONSerialization.jsonObject(with: Self.body(of: request)) as? [String: Any]
        let play = (body?["plays"] as? [[String: Any]])?.first
        #expect(play?["id"] as? String == "t1" && ((play?["listened_ms"] as? Int) ?? 0) >= 119_000)
    }

    @Test("with no Subsonic key: the API only — a refused sign-in says so, offline says so, nothing goes to /rest")
    func noKey() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { [self] request in
            request.url?.path == "/api/v2/me" ? json(Self.me) : .init(statusCode: 404, body: Data())
        }
        #expect(await source(mock.urlSession, key: false).checkConnection() == .ok)
        await #expect(throws: SourceError.signInRejected) { try await source(mock.urlSession, signedIn: false, key: false).playlists() }
        let offline = OfflineSwitch()
        offline.isOn = true
        await #expect(throws: SourceError.offline) { try await source(mock.urlSession, offline: offline, key: false).artists() }
        #expect(try await source(mock.urlSession, key: false).musicLibraries().isEmpty)
        try await source(mock.urlSession, key: false).reportNowPlaying(songId: "t1", positionSecs: 0)
        let paths = await mock.requestLog().compactMap(\.url?.path)
        #expect(paths.allSatisfy { !$0.hasPrefix("/rest/") }, "\(paths)")
    }

    @Test("a sign-in through the API keeps the tokens and the account's email, and fetches no Subsonic key")
    func signInWithoutKey() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { [self] request in
            switch request.url?.path {
            case "/api/v2/auth/token": return json(#"{"access_token":"a","refresh_token":"r","token_type":"Bearer","expires_in":3600,"scope":"library:read"}"#)
            case "/api/v2/me": return json(Self.me)
            default: return .init(statusCode: 404, body: Data())
            }
        }
        let result = try await ServerSetup.ownAudioSignIn(host: host, email: "Me@Example.com", password: "pw", deviceName: "test", urlSession: mock.urlSession)
        guard case .signedIn(let username, let tokens) = result else { Issue.record("\(result)"); return }
        #expect(username == "me@example.com" && tokens.refreshToken == "r")
        #expect(await mock.requestLog().compactMap(\.url?.path) == ["/api/v2/auth/token", "/api/v2/me"])
    }

    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

final class MemoryAnswers: AnswerCache, @unchecked Sendable {
    private var saved: [String: Data] = [:]
    private let lock = NSLock()
    func data(forKey key: String) -> Data? { lock.withLock { saved[key] } }
    func store(_ data: Data, forKey key: String) { lock.withLock { saved[key] = data } }
}

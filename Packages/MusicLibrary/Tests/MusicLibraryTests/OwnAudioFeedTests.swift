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
        #expect(artists.first?.imageURL?.absoluteString.hasSuffix("&w=512") == true)
    }

    @Test("changes: upserts and deletes applied, other kinds left out, the cursor moved on")
    func applyingChanges() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { request in
            #expect(request.url?.path == "/api/v2/sync/changes")
            let body = #"{"changes":[{"kind":"track","id":"t1","op":"upsert","record":{"id":"t1","title":"Song One (Live)","album_id":"al","recording_id":null,"credits":[],"genre_ids":[],"disc_number":1,"track_number":1,"duration_ms":200000,"visibility":"family","owner_id":"u","content_type":"audio/mpeg","size_bytes":1,"image":null,"created_at":"2026-10-11T12:00:00Z","updated_at":"2026-10-11T13:00:00Z"}},{"kind":"favourite.track","id":"t1","op":"delete"},{"kind":"book","id":"b1","op":"upsert","record":{"id":"b1"}}],"cursor":"c1","has_more":false,"reset":false}"#
            return .init(statusCode: 200, body: Data(body.utf8), headers: ["Content-Type": "application/json"])
        }
        let source = OwnAudioSource(
            subsonic: SubsonicSource(client: SubsonicClient(host: host, username: "u", password: "k", session: mock.urlSession)),
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
            subsonic: SubsonicSource(client: SubsonicClient(host: host, username: "u", password: "k", session: mock.urlSession)),
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
            subsonic: SubsonicSource(client: SubsonicClient(host: host, username: "u", password: "k", session: session)),
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

    private func source(_ session: URLSession, listener: ListenerState = ListenerState(), offline: OfflineSwitch? = nil, signedIn: Bool = true) -> OwnAudioSource {
        OwnAudioSource(
            subsonic: SubsonicSource(client: SubsonicClient(host: host, username: "me@example.com", password: "k", session: session)),
            client: OwnAudioClient(host: host, tokens: TokenSession(signedIn ? Tokens(accessToken: "a", refreshToken: "r", expiresAt: .distantFuture, scope: "") : nil), session: session),
            listener: listener, offline: offline
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
}

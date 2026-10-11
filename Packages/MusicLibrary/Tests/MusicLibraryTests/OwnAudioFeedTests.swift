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

import Foundation
import Testing

@testable import JellyfinKit

@Suite("JellyfinClient")
struct JellyfinClientTests {
    private let host = URL(string: "http://music.example.com:8096")!
    private let info = ClientInfo(client: "own.jelly", device: "iPhone", deviceId: "dev-1", version: "1.0")
    private let session = Session(userId: "u1", userName: "anna", accessToken: "tok", serverId: "s1")

    private func client(_ mock: MockURLProtocol.StubbedSession, offline: OfflineSwitch? = nil, cache: ResponseCache? = nil) -> JellyfinClient {
        JellyfinClient(host: host, session: session, clientInfo: info, urlSession: mock.urlSession, cache: cache, offline: offline)
    }

    private static func json(_ text: String) -> Data { Data(text.utf8) }

    // MARK: - Addresses and headers

    @Test("a bare host gets http and port 8096; https and explicit ports are kept")
    func normalizeHost() {
        #expect(JellyfinClient.normalizeHost("nas.local")?.absoluteString == "http://nas.local:8096")
        #expect(JellyfinClient.normalizeHost("nas.local:9000")?.absoluteString == "http://nas.local:9000")
        #expect(JellyfinClient.normalizeHost("https://jelly.example.com/")?.absoluteString == "https://jelly.example.com")
        #expect(JellyfinClient.normalizeHost("https://example.com/jellyfin")?.absoluteString == "https://example.com/jellyfin")
        #expect(JellyfinClient.normalizeHost("  ") == nil)
    }

    @Test("without a scheme, https comes first, then http on 8096, then plain http")
    func candidateHosts() {
        #expect(JellyfinClient.candidateHosts("demo.jellyfin.org/stable").map(\.absoluteString) == [
            "https://demo.jellyfin.org/stable", "http://demo.jellyfin.org:8096/stable", "http://demo.jellyfin.org/stable",
        ])
        #expect(JellyfinClient.candidateHosts("nas.local:9000").map(\.absoluteString) == ["https://nas.local:9000", "http://nas.local:9000"])
        #expect(JellyfinClient.candidateHosts("http://nas.local").map(\.absoluteString) == ["http://nas.local"])
    }

    @Test("every request carries the MediaBrowser header with the token")
    func authorizationHeader() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in .init(statusCode: 200, body: Self.json(#"{"Items":[]}"#)) }
        _ = try await client(mock).playlists()
        let header = await mock.requestLog().first?.value(forHTTPHeaderField: "Authorization")
        #expect(header == #"MediaBrowser Client="own.jelly", Device="iPhone", DeviceId="dev-1", Version="1.0", Token="tok""#)
    }

    @Test("sign-in posts the name and password and returns the session")
    func signIn() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            .init(statusCode: 200, body: Self.json(#"{"User":{"Id":"u1","Name":"anna"},"AccessToken":"tok","ServerId":"s1"}"#))
        }
        let result = try await JellyfinClient.signIn(host: host, username: "anna", password: "pw", clientInfo: info, urlSession: mock.urlSession)
        #expect(result == session)
        let request = try #require(await mock.requestLog().first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/Users/AuthenticateByName")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=") == false)
    }

    @Test("401 is unauthorized, 404 not found, a transport failure network")
    func errors() async throws {
        let unauthorized = await MockURLProtocol.makeStubbedSession { _ in .init(statusCode: 401, body: Data()) }
        await #expect(throws: JellyfinClient.JellyfinError.unauthorized) { try await client(unauthorized).playlists() }
        let down = await MockURLProtocol.makeStubbedSession { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: JellyfinClient.JellyfinError.network) { try await client(down).playlists() }
        #expect(await client(unauthorized).checkSession() == .rejected)
        #expect(await client(down).checkSession() == .unreachable)
    }

    // MARK: - Decoding

    @Test("a song: ticks to seconds, disc 0 is no disc, the album's cover when it has none")
    func songDecoding() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            .init(statusCode: 200, body: Self.json(#"""
            {"Items":[{"Id":"s1","Name":"One","Type":"Audio","Album":"Opera","AlbumId":"al1",
            "AlbumPrimaryImageTag":"t","ImageTags":{},"RunTimeTicks":2135000000,"IndexNumber":3,
            "ParentIndexNumber":0,"Genres":["Rock"],"ArtistItems":[{"Name":"Queen","Id":"ar1"}],
            "UserData":{"IsFavorite":true,"PlayCount":4},"Container":"flac",
            "MediaSources":[{"Container":"flac","Bitrate":900000}],"NormalizationGain":-6.5,
            "HasLyrics":true,"DateCreated":"2025-02-22T21:32:03.1234567Z"}]}
            """#))
        }
        let song = try #require(try await client(mock).songs().first)
        #expect(song.duration == 214)
        #expect(song.discNumber == nil)
        #expect(song.track == 3)
        #expect(song.coverArt == "al1")
        #expect(song.artist == "Queen")
        #expect(song.artistId == "ar1")
        #expect(song.isFavorite)
        #expect(song.playCount == 4)
        #expect(song.suffix == "flac")
        #expect(song.bitRate == 900000)
        #expect(song.normalizationGain == -6.5)
        #expect(song.hasLyrics)
    }

    @Test("an album: its own cover, album artist, child count as song count, date added")
    func albumDecoding() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            .init(statusCode: 200, body: Self.json(#"""
            {"Items":[{"Id":"al1","Name":"72 Seasons","Type":"MusicAlbum","AlbumArtist":"Metallica",
            "AlbumArtists":[{"Name":"Metallica","Id":"ar1"}],"ImageTags":{"Primary":"x"},
            "ChildCount":12,"ProductionYear":2023,"RunTimeTicks":46307466660,
            "DateCreated":"2025-02-22T21:32:03.0000000Z"}]}
            """#))
        }
        let album = try #require(try await client(mock).albums(.newest).first)
        #expect(album.coverArt == "al1")
        #expect(album.artist == "Metallica")
        #expect(album.artistId == "ar1")
        #expect(album.songCount == 12)
        #expect(album.year == 2023)
        #expect(album.duration == 4631)
        #expect(album.dateAdded == Transport.parseDate("2025-02-22T21:32:03Z"))
        let query = await mock.firstQuery()
        #expect(query.first { $0.name == "SortBy" }?.value == "DateCreated,SortName")
        #expect(query.first { $0.name == "SortOrder" }?.value == "Descending")
    }

    @Test("seven fractional digits and none both parse")
    func dates() {
        #expect(Transport.parseDate("2025-02-22T21:32:03.0000000Z") != nil)
        #expect(Transport.parseDate("2025-02-22T21:32:03Z") != nil)
        #expect(Transport.parseDate("2025-04-30T17:19:59.3360864Z")!.timeIntervalSince(Transport.parseDate("2025-04-30T17:19:59Z")!) > 0.33)
    }

    @Test("synced lyrics: ticks to milliseconds; 404 means none")
    func lyrics() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { request in
            if request.url?.path.contains("none") == true { return .init(statusCode: 404, body: Data()) }
            return .init(statusCode: 200, body: Self.json(#"{"Lyrics":[{"Text":"Hello","Start":15000000},{"Text":"World","Start":32000000}]}"#))
        }
        let lyrics = try #require(try await client(mock).lyrics(songId: "s1"))
        #expect(lyrics.isSynced)
        #expect(lyrics.lines.map(\.startMs) == [1500, 3200])
        #expect(lyrics.lineIndex(at: 2) == 0)
        #expect(try await client(mock).lyrics(songId: "none") == nil)
    }

    // MARK: - Requests

    @Test("a library choice limits listings to it")
    func libraryScope() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in .init(statusCode: 200, body: Self.json(#"{"Items":[]}"#)) }
        let scoped = JellyfinClient(host: host, session: session, libraryId: "lib", clientInfo: info, urlSession: mock.urlSession)
        _ = try await scoped.albums(.name)
        #expect(await mock.firstQuery().first { $0.name == "ParentId" }?.value == "lib")
    }

    @Test("removing from a playlist goes by entry id; favorites post and delete")
    func writes() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in .init(statusCode: 204, body: Data()) }
        let api = client(mock)
        try await api.removeFromPlaylist(id: "p1", entryIds: ["e1", "e2"])
        try await api.setFavorite("s1", true)
        try await api.setFavorite("s1", false)
        let log = await mock.requestLog()
        #expect(log[0].httpMethod == "DELETE")
        #expect(log[0].url?.path == "/Playlists/p1/Items")
        #expect(log[0].url?.query?.contains("entryIds=e1,e2") == true)
        #expect(log[1].httpMethod == "POST")
        #expect(log[1].url?.path == "/UserFavoriteItems/s1")
        #expect(log[2].httpMethod == "DELETE")
    }

    @Test("playlists: imported ones (media type Unknown) are listed, video ones are not")
    func playlistsKeepUnknownMediaType() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            .init(statusCode: 200, body: Self.json(#"""
            {"Items":[{"Id":"p1","Name":"From m3u","ChildCount":17,"MediaType":"Unknown"},
            {"Id":"p2","Name":"Made here","ChildCount":3,"MediaType":"Audio"},
            {"Id":"p3","Name":"Films","ChildCount":2,"MediaType":"Video"}]}
            """#))
        }
        #expect(try await client(mock).playlists().map(\.name) == ["From m3u", "Made here"])
        #expect(await mock.firstQuery().contains { $0.name == "MediaTypes" } == false)
    }

    @Test("the stream URL is the original file, with the token for the player")
    func streamURL() {
        let api = JellyfinClient(host: host, session: session, clientInfo: info)
        let url = api.streamURL(songId: "s1")
        #expect(url.path == "/Audio/s1/stream")
        #expect(url.query?.contains("static=true") == true)
        #expect(url.query?.contains("ApiKey=tok") == true)
        let smaller = api.streamURL(songId: "s1", maxBitrate: 128_000)
        #expect(smaller.path == "/Audio/s1/stream.mp3")
        #expect(smaller.query?.contains("audioBitRate=128000") == true)
        #expect(smaller.query?.contains("static=false") == true)
    }

    // MARK: - Offline

    @Test("a saved answer comes back offline and when the request fails; writes are refused offline")
    func offlineCache() async throws {
        actor Network { var isUp = true; func set(_ up: Bool) { isUp = up } }
        let network = Network()
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            guard await network.isUp else { throw URLError(.notConnectedToInternet) }
            return .init(statusCode: 200, body: Self.json(#"{"Items":[{"Id":"p1","Name":"Mix","ChildCount":3}]}"#))
        }
        let offline = OfflineSwitch()
        let cache = DiskResponseCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let api = client(mock, offline: offline, cache: cache)
        _ = try await api.playlists()
        await network.set(false)
        #expect(try await api.playlists().map(\.name) == ["Mix"])
        offline.isOn = true
        #expect(try await api.playlists().map(\.name) == ["Mix"])
        await #expect(throws: JellyfinClient.JellyfinError.offline) { try await api.setFavorite("s1", true) }
        await #expect(throws: JellyfinClient.JellyfinError.offline) { try await api.genres() }
        #expect(await mock.requestLog().count == 2)
    }
}

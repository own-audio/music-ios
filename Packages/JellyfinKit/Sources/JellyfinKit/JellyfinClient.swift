import Foundation

/// How this app introduces itself. Jellyfin lists sessions by device, so the id has to stay the
/// same across launches; the app keeps one.
public struct ClientInfo: Sendable, Equatable {
    public let client: String
    public let device: String
    public let deviceId: String
    public let version: String

    public init(client: String, device: String, deviceId: String, version: String) {
        self.client = client
        self.device = device
        self.deviceId = deviceId
        self.version = version
    }

    /// The `Authorization: MediaBrowser …` value. Values are quoted, so quotes in them go.
    func header(token: String?) -> String {
        func clean(_ value: String) -> String { value.replacingOccurrences(of: "\"", with: "") }
        var parts = [
            "Client=\"\(clean(client))\"", "Device=\"\(clean(device))\"",
            "DeviceId=\"\(clean(deviceId))\"", "Version=\"\(clean(version))\"",
        ]
        if let token { parts.append("Token=\"\(clean(token))\"") }
        return "MediaBrowser " + parts.joined(separator: ", ")
    }
}

/// A client for a Jellyfin server's music. Written by hand against the REST API: a music player
/// needs a few dozen endpoints, and a client generated from the full API would mostly be code
/// for video, TV and administration.
public struct JellyfinClient: Sendable {
    public enum JellyfinError: Error, Sendable, Equatable {
        /// The token is no longer accepted (signed out elsewhere, or the user was removed).
        case unauthorized
        case forbidden
        case notFound
        case http(Int)
        case decoding
        case network
        /// Offline, and this wasn't saved from an earlier visit.
        case offline
    }

    public let host: URL
    public let session: Session
    /// Restricts listings to one music library; nil means all of them.
    public let libraryId: String?
    private let clientInfo: ClientInfo
    private let urlSession: URLSession
    private let cache: ResponseCache?
    private let offline: OfflineSwitch?

    public init(
        host: URL, session: Session, libraryId: String? = nil, clientInfo: ClientInfo,
        urlSession: URLSession = .shared, cache: ResponseCache? = nil, offline: OfflineSwitch? = nil
    ) {
        self.host = host
        self.session = session
        self.libraryId = libraryId
        self.clientInfo = clientInfo
        self.urlSession = urlSession
        self.cache = cache
        self.offline = offline
    }

    /// Accepts "host", "host:port" or a full URL. A bare host gets http and, without a port,
    /// Jellyfin's default 8096, which is how most home servers are reached; an explicit
    /// https:// is kept as given.
    public static func normalizeHost(_ rawInput: String) -> URL? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let hasScheme = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
        guard var components = URLComponents(string: hasScheme ? trimmed : "http://\(trimmed)"),
              components.host?.isEmpty == false
        else { return nil }
        if !hasScheme, components.port == nil { components.port = 8096 }
        if components.path.hasSuffix("/") { components.path.removeLast() }
        return components.url
    }

    /// The addresses to try for what was typed. With a scheme, just that. Without one, https
    /// first (a server behind a proxy or on a public name), then http on Jellyfin's port 8096
    /// (a server at home), then plain http.
    public static func candidateHosts(_ rawInput: String) -> [URL] {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return normalizeHost(trimmed).map { [$0] } ?? []
        }
        guard let home = normalizeHost(trimmed) else { return [] }
        var candidates: [URL] = []
        if let secure = normalizeHost("https://\(trimmed)") { candidates.append(secure) }
        candidates.append(home)
        if let plain = normalizeHost("http://\(trimmed)"), plain != home { candidates.append(plain) }
        return candidates
    }

    // MARK: - Before signing in

    /// Name and version, without signing in; also tells whether there is a Jellyfin there at all.
    public static func serverInfo(host: URL, urlSession: URLSession = .shared) async throws -> ServerInfo {
        let request = URLRequest(url: host.appending(path: "System/Info/Public"))
        return try await Transport.decode(Transport.send(request, session: urlSession))
    }

    public static func signIn(
        host: URL, username: String, password: String, clientInfo: ClientInfo, urlSession: URLSession = .shared
    ) async throws -> Session {
        var request = URLRequest(url: host.appending(path: "Users/AuthenticateByName"))
        request.httpMethod = "POST"
        request.setValue(clientInfo.header(token: nil), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["Username": username, "Pw": password])
        let response: AuthResponse = try await Transport.decode(Transport.send(request, session: urlSession))
        return response.session
    }

    /// Quick Connect: the app shows a code, the listener approves it in another signed-in
    /// Jellyfin app, and this device gets a session without typing a password.
    public struct QuickConnect: Sendable, Equatable {
        public let secret: String
        public let code: String
        public let isApproved: Bool
    }

    public static func isQuickConnectEnabled(host: URL, urlSession: URLSession = .shared) async -> Bool {
        let request = URLRequest(url: host.appending(path: "QuickConnect/Enabled"))
        guard let data = try? await Transport.send(request, session: urlSession) else { return false }
        return (try? JSONDecoder().decode(Bool.self, from: data)) ?? false
    }

    public static func startQuickConnect(host: URL, clientInfo: ClientInfo, urlSession: URLSession = .shared) async throws -> QuickConnect {
        var request = URLRequest(url: host.appending(path: "QuickConnect/Initiate"))
        request.httpMethod = "POST"
        request.setValue(clientInfo.header(token: nil), forHTTPHeaderField: "Authorization")
        let dto: QuickConnectDTO = try await Transport.decode(Transport.send(request, session: urlSession))
        return QuickConnect(secret: dto.secret, code: dto.code, isApproved: dto.authenticated)
    }

    public static func checkQuickConnect(host: URL, secret: String, urlSession: URLSession = .shared) async throws -> QuickConnect {
        var url = host.appending(path: "QuickConnect/Connect")
        url.append(queryItems: [URLQueryItem(name: "secret", value: secret)])
        let dto: QuickConnectDTO = try await Transport.decode(Transport.send(URLRequest(url: url), session: urlSession))
        return QuickConnect(secret: dto.secret, code: dto.code, isApproved: dto.authenticated)
    }

    public static func finishQuickConnect(
        host: URL, secret: String, clientInfo: ClientInfo, urlSession: URLSession = .shared
    ) async throws -> Session {
        var request = URLRequest(url: host.appending(path: "Users/AuthenticateWithQuickConnect"))
        request.httpMethod = "POST"
        request.setValue(clientInfo.header(token: nil), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["Secret": secret])
        let response: AuthResponse = try await Transport.decode(Transport.send(request, session: urlSession))
        return response.session
    }

    // MARK: - Session

    /// Whether the saved token still works.
    public func checkSession() async -> ConnectionStatus {
        do {
            let _: ItemDTO = try await get("Users/Me", cached: false)
            return .ok
        } catch JellyfinError.unauthorized, JellyfinError.forbidden {
            return .rejected
        } catch {
            return .unreachable
        }
    }

    /// Ends the session on the server, so it disappears from the dashboard's device list.
    public func signOut() async {
        _ = try? await send("POST", "Sessions/Logout")
    }

    // MARK: - Browsing

    public func musicLibraries() async throws -> [MusicLibrary] {
        let response: ItemsResponse = try await get("UserViews", query: ["userId": session.userId])
        return response.items.filter { $0.collectionType == "music" }.map { MusicLibrary(id: $0.id, name: $0.name ?? "") }
    }

    /// Album artists, the way music apps list artists: one entry per artist with albums.
    public func artists() async throws -> [Artist] {
        let response: ItemsResponse = try await get("Artists/AlbumArtists", query: libraryQuery([
            "userId": session.userId, "SortBy": "SortName", "Fields": "ChildCount",
            "EnableUserData": "true", "EnableImageTypes": "Primary",
        ]))
        return response.items.map(\.asArtist)
    }

    public func albums(_ sort: AlbumSort, limit: Int = 60, offset: Int = 0) async throws -> [Album] {
        var query = albumQuery(limit: limit, offset: offset)
        switch sort {
        case .name: query["SortBy"] = "SortName"
        case .artist: query["SortBy"] = "AlbumArtist,SortName"
        case .newest: query["SortBy"] = "DateCreated,SortName"; query["SortOrder"] = "Descending"
        case .mostPlayed: query["SortBy"] = "PlayCount,SortName"; query["SortOrder"] = "Descending"
        case .random: query["SortBy"] = "Random"
        case .favorites: query["SortBy"] = "SortName"; query["Filters"] = "IsFavorite"
        case .recentlyPlayed: return try await recentlyPlayedAlbums(limit: limit)
        }
        let response: ItemsResponse = try await get("Items", query: query, cached: sort != .random)
        return response.items.map(\.asAlbum)
    }

    /// Albums don't record when they were last played; their songs do. So this reads recently
    /// played songs and keeps the first appearance of each album.
    private func recentlyPlayedAlbums(limit: Int) async throws -> [Album] {
        let response: ItemsResponse = try await get("Items", query: libraryQuery([
            "userId": session.userId, "IncludeItemTypes": "Audio", "Recursive": "true",
            "Filters": "IsPlayed", "SortBy": "DatePlayed", "SortOrder": "Descending",
            "Limit": String(limit * 5), "Fields": "ParentId",
        ]))
        var seen = Set<String>()
        let albumIds = response.items.compactMap(\.albumId).filter { seen.insert($0).inserted }.prefix(limit)
        guard !albumIds.isEmpty else { return [] }
        let albums: ItemsResponse = try await get("Items", query: [
            "userId": session.userId, "Ids": albumIds.joined(separator: ","),
            "Fields": "Genres,DateCreated,ChildCount", "EnableUserData": "true",
        ])
        let byId = Dictionary(albums.items.map { ($0.id, $0.asAlbum) }, uniquingKeysWith: { a, _ in a })
        return albumIds.compactMap { byId[$0] }
    }

    public func albums(artistId: String) async throws -> [Album] {
        var query = albumQuery(limit: nil, offset: 0)
        query["AlbumArtistIds"] = artistId
        query["SortBy"] = "ProductionYear,SortName"
        let response: ItemsResponse = try await get("Items", query: query)
        return response.items.map(\.asAlbum)
    }

    public func albums(genreId: String, limit: Int = 200) async throws -> [Album] {
        var query = albumQuery(limit: limit, offset: 0)
        query["GenreIds"] = genreId
        query["SortBy"] = "SortName"
        let response: ItemsResponse = try await get("Items", query: query)
        return response.items.map(\.asAlbum)
    }

    /// An album and its songs in disc and track order.
    public func album(id: String) async throws -> (album: Album, songs: [Song]) {
        async let item: ItemDTO = get("Items/\(id)", query: ["userId": session.userId, "Fields": "Genres,DateCreated,ChildCount"])
        async let tracks: ItemsResponse = get("Items", query: [
            "userId": session.userId, "ParentId": id, "IncludeItemTypes": "Audio",
            "SortBy": "ParentIndexNumber,IndexNumber,SortName", "Fields": Self.songFields,
            "EnableUserData": "true",
        ])
        return try await (item.asAlbum, tracks.items.map(\.asSong))
    }

    public func song(id: String) async throws -> Song {
        let item: ItemDTO = try await get("Items/\(id)", query: ["userId": session.userId, "Fields": Self.songFields])
        return item.asSong
    }

    /// Every song, a page at a time, by title.
    public func songs(limit: Int = 100, offset: Int = 0) async throws -> [Song] {
        let response: ItemsResponse = try await get("Items", query: songQuery([
            "SortBy": "SortName", "Limit": String(limit), "StartIndex": String(offset),
        ]))
        return response.items.map(\.asSong)
    }

    public func randomSongs(limit: Int = 100, genreId: String? = nil) async throws -> [Song] {
        var extra = ["SortBy": "Random", "Limit": String(limit)]
        if let genreId { extra["GenreIds"] = genreId }
        let response: ItemsResponse = try await get("Items", query: songQuery(extra), cached: false)
        return response.items.map(\.asSong)
    }

    public func genres() async throws -> [Genre] {
        let response: ItemsResponse = try await get("MusicGenres", query: libraryQuery([
            "userId": session.userId, "SortBy": "SortName", "Fields": "ItemCounts",
        ]))
        return response.items.map(\.asGenre)
    }

    /// Artists, albums and songs matching `text`, one request per kind so each gets its own
    /// share of results.
    public func search(_ text: String, limit: Int = 20) async throws -> SearchResult {
        async let artists: ItemsResponse = get("Artists/AlbumArtists", query: libraryQuery([
            "userId": session.userId, "SearchTerm": text, "Limit": String(limit),
            "EnableImageTypes": "Primary",
        ]), cached: false)
        async let albums: ItemsResponse = get("Items", query: albumQuery(limit: limit, offset: 0).merging(
            ["SearchTerm": text], uniquingKeysWith: { _, new in new }
        ), cached: false)
        async let songs: ItemsResponse = get("Items", query: songQuery(["SearchTerm": text, "Limit": String(limit)]), cached: false)
        return try await SearchResult(
            artists: artists.items.map(\.asArtist), albums: albums.items.map(\.asAlbum), songs: songs.items.map(\.asSong)
        )
    }

    /// Songs like this song, album or artist, picked by the server.
    public func instantMix(itemId: String, limit: Int = 100) async throws -> [Song] {
        let response: ItemsResponse = try await get("Items/\(itemId)/InstantMix", query: [
            "userId": session.userId, "Limit": String(limit), "Fields": Self.songFields,
            "EnableUserData": "true",
        ], cached: false)
        return response.items.map(\.asSong)
    }

    // MARK: - Favorites

    public func favorites() async throws -> FavoritesResult {
        async let artists: ItemsResponse = get("Artists/AlbumArtists", query: libraryQuery([
            "userId": session.userId, "IsFavorite": "true", "SortBy": "SortName",
            "EnableUserData": "true", "EnableImageTypes": "Primary",
        ]))
        async let albums: ItemsResponse = get("Items", query: albumQuery(limit: nil, offset: 0).merging(
            ["Filters": "IsFavorite", "SortBy": "SortName"], uniquingKeysWith: { _, new in new }
        ))
        async let songs: ItemsResponse = get("Items", query: songQuery(["Filters": "IsFavorite", "SortBy": "SortName"]))
        return try await FavoritesResult(
            artists: artists.items.map(\.asArtist), albums: albums.items.map(\.asAlbum), songs: songs.items.map(\.asSong)
        )
    }

    /// Favorites are per user and work the same for songs, albums and artists.
    public func setFavorite(_ itemId: String, _ isFavorite: Bool) async throws {
        _ = try await send(isFavorite ? "POST" : "DELETE", "UserFavoriteItems/\(itemId)", query: ["userId": session.userId])
    }

    // MARK: - Playlists

    /// Every playlist but video ones. Not filtered to audio on the server: playlists imported
    /// from .m3u files come with media type "Unknown", and those would be left out.
    public func playlists() async throws -> [Playlist] {
        let response: ItemsResponse = try await get("Items", query: [
            "userId": session.userId, "IncludeItemTypes": "Playlist", "Recursive": "true",
            "SortBy": "SortName", "Fields": "ChildCount",
        ])
        return response.items.filter { $0.mediaType != "Video" }.map(\.asPlaylist)
    }

    public func playlist(id: String) async throws -> (playlist: Playlist, songs: [Song]) {
        async let item: ItemDTO = get("Items/\(id)", query: ["userId": session.userId, "Fields": "ChildCount"])
        async let entries: ItemsResponse = get("Playlists/\(id)/Items", query: [
            "userId": session.userId, "Fields": Self.songFields, "EnableUserData": "true",
        ])
        return try await (item.asPlaylist, entries.items.map(\.asSong))
    }

    @discardableResult
    public func createPlaylist(name: String, songIds: [String] = []) async throws -> String {
        let body: [String: AnyEncodable] = [
            "Name": AnyEncodable(name), "Ids": AnyEncodable(songIds),
            "UserId": AnyEncodable(session.userId), "MediaType": AnyEncodable("Audio"),
        ]
        let data = try await send("POST", "Playlists", body: body)
        let created: CreatedDTO = try Transport.decode(data)
        return created.id
    }

    public func addToPlaylist(id: String, songIds: [String]) async throws {
        _ = try await send("POST", "Playlists/\(id)/Items", query: [
            "ids": songIds.joined(separator: ","), "userId": session.userId,
        ])
    }

    /// By the entries' `playlistItemId`, not the song ids.
    public func removeFromPlaylist(id: String, entryIds: [String]) async throws {
        _ = try await send("DELETE", "Playlists/\(id)/Items", query: ["entryIds": entryIds.joined(separator: ",")])
    }

    public func renamePlaylist(id: String, to name: String) async throws {
        _ = try await send("POST", "Playlists/\(id)", body: ["Name": AnyEncodable(name)])
    }

    public func deletePlaylist(id: String) async throws {
        _ = try await send("DELETE", "Items/\(id)")
    }

    // MARK: - Lyrics

    /// Empty when the song has none.
    public func lyrics(songId: String) async throws -> Lyrics? {
        let dto: LyricsDTO
        do {
            dto = try await get("Audio/\(songId)/Lyrics")
        } catch JellyfinError.notFound {
            return nil
        }
        let lines = (dto.lyrics ?? []).map { Lyrics.Line(startMs: $0.start.map { Int($0 / 10_000) }, text: $0.text ?? "") }
        guard !lines.isEmpty else { return nil }
        return Lyrics(lines: lines, isSynced: lines.contains { $0.startMs != nil })
    }

    // MARK: - Playback reporting

    /// Shows the song on the server's dashboard as playing on this device.
    public func reportStart(songId: String, positionSecs: Double = 0) async throws {
        _ = try await send("POST", "Sessions/Playing", body: playbackBody(songId: songId, positionSecs: positionSecs, isPaused: false))
    }

    public func reportProgress(songId: String, positionSecs: Double, isPaused: Bool) async throws {
        _ = try await send("POST", "Sessions/Playing/Progress", body: playbackBody(songId: songId, positionSecs: positionSecs, isPaused: isPaused))
    }

    public func reportStopped(songId: String, positionSecs: Double) async throws {
        _ = try await send("POST", "Sessions/Playing/Stopped", body: playbackBody(songId: songId, positionSecs: positionSecs, isPaused: false))
    }

    /// Counts a play: the play count goes up and "last played" moves. `at` is when it was heard,
    /// for plays reported late after being offline.
    public func markPlayed(songId: String, at date: Date? = nil) async throws {
        var query = ["userId": session.userId]
        if let date { query["datePlayed"] = ISO8601DateFormatter().string(from: date) }
        _ = try await send("POST", "UserPlayedItems/\(songId)", query: query)
    }

    private func playbackBody(songId: String, positionSecs: Double, isPaused: Bool) -> [String: AnyEncodable] {
        [
            "ItemId": AnyEncodable(songId), "PositionTicks": AnyEncodable(Int64(positionSecs * 10_000_000)),
            "IsPaused": AnyEncodable(isPaused), "CanSeek": AnyEncodable(true),
            "PlayMethod": AnyEncodable("DirectPlay"),
        ]
    }

    // MARK: - URLs for the player and image loading

    /// The original file, or with `maxBitrate` (bits per second) an MP3 the server makes on the
    /// fly at that rate, to save mobile data. The token goes in the query because the player
    /// fetches the URL as is.
    public func streamURL(songId: String, maxBitrate: Int? = nil) -> URL {
        guard let maxBitrate else {
            var url = host.appending(path: "Audio/\(songId)/stream")
            url.append(queryItems: [
                URLQueryItem(name: "static", value: "true"),
                URLQueryItem(name: "ApiKey", value: session.accessToken),
            ])
            return url
        }
        // MP3 because the player decodes it in pieces as it arrives, and every server's ffmpeg
        // can make it.
        var url = host.appending(path: "Audio/\(songId)/stream.mp3")
        url.append(queryItems: [
            URLQueryItem(name: "static", value: "false"),
            URLQueryItem(name: "audioCodec", value: "mp3"),
            URLQueryItem(name: "audioBitRate", value: String(maxBitrate)),
            URLQueryItem(name: "ApiKey", value: session.accessToken),
        ])
        return url
    }

    /// Images need no sign-in on Jellyfin. `size` is in pixels; the server scales and crops.
    public func imageURL(itemId: String, size: Int) -> URL {
        var url = host.appending(path: "Items/\(itemId)/Images/Primary")
        url.append(queryItems: [
            URLQueryItem(name: "fillWidth", value: String(size)),
            URLQueryItem(name: "fillHeight", value: String(size)),
            URLQueryItem(name: "quality", value: "90"),
        ])
        return url
    }

    // MARK: - Queries

    static let songFields = "Genres,MediaSources,ParentId"

    private func libraryQuery(_ query: [String: String]) -> [String: String] {
        guard let libraryId else { return query }
        return query.merging(["ParentId": libraryId], uniquingKeysWith: { old, _ in old })
    }

    private func albumQuery(limit: Int?, offset: Int) -> [String: String] {
        var query = libraryQuery([
            "userId": session.userId, "IncludeItemTypes": "MusicAlbum", "Recursive": "true",
            "Fields": "Genres,DateCreated,ChildCount", "EnableUserData": "true",
            "EnableImageTypes": "Primary", "StartIndex": String(offset),
        ])
        if let limit { query["Limit"] = String(limit) }
        return query
    }

    private func songQuery(_ extra: [String: String]) -> [String: String] {
        libraryQuery([
            "userId": session.userId, "IncludeItemTypes": "Audio", "Recursive": "true",
            "Fields": Self.songFields, "EnableUserData": "true",
        ]).merging(extra, uniquingKeysWith: { _, new in new })
    }

    // MARK: - Transport

    /// The request without the token, so the same question maps to the same saved answer.
    func cacheKey(path: String, query: [String: String]) -> String {
        let params = query.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "&")
        return "\(host.absoluteString)|\(session.userId)|\(path)?\(params)"
    }

    /// GETs are saved for offline use unless `cached` is false (search, random picks: an old
    /// answer to those misleads). Offline, a saved answer or `.offline` without touching the
    /// network; online, a failed request falls back to the saved answer.
    private func get<T: Decodable>(_ path: String, query: [String: String] = [:], cached: Bool = true) async throws -> T {
        let key = cached && cache != nil ? cacheKey(path: path, query: query) : nil
        let saved = { key.flatMap { cache?.data(forKey: $0) } }
        if offline?.isOn == true {
            guard let data = saved() else { throw JellyfinError.offline }
            return try Transport.decode(data)
        }
        let data: Data
        do {
            data = try await send("GET", path, query: query)
        } catch JellyfinError.network {
            guard let data = saved() else { throw JellyfinError.network }
            return try Transport.decode(data)
        }
        let decoded: T = try Transport.decode(data)
        if let key { cache?.store(data, forKey: key) }
        return decoded
    }

    private func send(
        _ method: String, _ path: String, query: [String: String] = [:], body: [String: AnyEncodable]? = nil
    ) async throws -> Data {
        if method != "GET", offline?.isOn == true { throw JellyfinError.offline }
        var url = host.appending(path: path)
        if !query.isEmpty {
            url.append(queryItems: query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) })
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(clientInfo.header(token: session.accessToken), forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return try await Transport.send(request, session: urlSession)
    }
}

public enum ConnectionStatus: Equatable, Sendable {
    case ok
    case rejected
    case unreachable
}

/// Lets request bodies mix strings, numbers, booleans and arrays.
struct AnyEncodable: Encodable, Sendable {
    private let encodeValue: @Sendable (Encoder) throws -> Void

    init<T: Encodable & Sendable>(_ value: T) {
        encodeValue = { try value.encode(to: $0) }
    }

    func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }
}

enum Transport {
    typealias JellyfinError = JellyfinClient.JellyfinError

    static func send(_ request: URLRequest, session: URLSession) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw JellyfinError.network
        }
        guard let http = response as? HTTPURLResponse else { throw JellyfinError.network }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw JellyfinError.unauthorized
        case 403: throw JellyfinError.forbidden
        case 404: throw JellyfinError.notFound
        default: throw JellyfinError.http(http.statusCode)
        }
    }

    static func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw JellyfinError.decoding
        }
    }

    /// Jellyfin writes dates with seven fractional digits ("2025-02-22T21:32:03.0000000Z"),
    /// more than `ISO8601DateFormatter` reads, so the fraction is cut to milliseconds first.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = parseDate(raw) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unreadable date \(raw)"))
        }
        return decoder
    }()

    static func parseDate(_ raw: String) -> Date? {
        var text = raw
        if let dot = text.firstIndex(of: ".") {
            let fractionEnd = text[dot...].dropFirst().firstIndex { !$0.isNumber } ?? text.endIndex
            let digits = text[text.index(after: dot)..<fractionEnd].prefix(3)
            text = String(text[..<dot]) + "." + digits.padding(toLength: 3, withPad: "0", startingAt: 0) + String(text[fractionEnd...])
        }
        if !text.hasSuffix("Z"), !text.contains("+"), text.count <= 23 { text += "Z" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}

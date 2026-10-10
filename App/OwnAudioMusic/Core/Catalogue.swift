import Foundation
import MusicLibrary

/// One server's whole library — artists, albums, songs, playlists — kept on the phone, so an
/// album never opened before still opens offline, and the offline library can show everything
/// rather than only the downloads. Synced in the background; the server stays the authority.
final class Catalogue: Sendable {
    struct Snapshot: Codable, Sendable {
        var artists: [Artist]
        var albums: [Album]
        var songs: [Song]
        var playlists: [Playlist]
        var syncedAt: Date
    }

    let snapshot: Snapshot
    /// In album order: artist, album, disc, track.
    let songs: [Song]
    let albums: [Album]
    let artists: [Artist]
    let genres: [Genre]
    private let songsByAlbum: [String: [Song]]
    private let songsByAlbumName: [String: [Song]]
    private let albumsByArtist: [String: [Album]]

    init(_ snapshot: Snapshot) {
        self.snapshot = snapshot
        songs = snapshot.songs.sorted(by: Self.albumOrder)
        albums = snapshot.albums.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        artists = snapshot.artists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        songsByAlbum = Dictionary(grouping: songs) { $0.albumId ?? "" }
        songsByAlbumName = Dictionary(grouping: songs) { $0.album?.lowercased() ?? "" }
        albumsByArtist = Dictionary(grouping: albums) { $0.artistId ?? $0.artist ?? "" }
        genres = Dictionary(grouping: snapshot.songs) { $0.genre ?? "" }
            .compactMap { name, songs -> Genre? in
                guard !name.isEmpty else { return nil }
                return Genre(id: name, name: name, albumCount: Set(songs.compactMap(\.albumId)).count, songCount: songs.count)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// By id; where no song carries the album's id, by name (own.audio up to 1.0.0-beta.3 gave
    /// songs shared from another family member's library an album id the listener can't use).
    func songs(album: Album) -> [Song] {
        if let songs = songsByAlbum[album.id] { return songs }
        return songsByAlbumName[album.name.lowercased()] ?? []
    }

    func albums(artist: Artist) -> [Album] {
        albumsByArtist[artist.id] ?? albumsByArtist[artist.name] ?? []
    }

    static func albumOrder(_ a: Song, _ b: Song) -> Bool {
        let keyA = (a.artist ?? "", a.album ?? "", a.discNumber ?? 1, a.track ?? 0)
        let keyB = (b.artist ?? "", b.album ?? "", b.discNumber ?? 1, b.track ?? 0)
        if keyA.0 != keyB.0 { return keyA.0.localizedStandardCompare(keyB.0) == .orderedAscending }
        if keyA.1 != keyB.1 { return keyA.1.localizedStandardCompare(keyB.1) == .orderedAscending }
        if keyA.2 != keyB.2 { return keyA.2 < keyB.2 }
        return keyA.3 < keyB.3
    }

    /// Everything the server lists, page by page. Some Subsonic servers don't list songs without
    /// a search term; their songs are then read album by album.
    static func fetch(from source: any MusicSource) async throws -> Snapshot {
        let page = 500
        let artists = try await source.artists()
        var albums: [Album] = []
        while true {
            let next = try await source.albums(.name, limit: page, offset: albums.count)
            albums += next
            if next.count < page { break }
        }
        var songs: [Song] = []
        while true {
            let next = try await source.songs(limit: page, offset: songs.count)
            songs += next
            if next.count < page { break }
        }
        if songs.isEmpty, !albums.isEmpty {
            for album in albums {
                try Task.checkCancellation()
                songs += try await source.album(id: album.id).songs
            }
        }
        // Two pages can overlap if the library changes during the sync.
        var seen = Set<String>()
        songs = songs.filter { seen.insert($0.id).inserted }
        let playlists = (try? await source.playlists()) ?? []
        return Snapshot(artists: artists, albums: albums, songs: songs, playlists: playlists, syncedAt: Date())
    }
}

/// One file per server in Application Support: unlike the saved answers in Caches, iOS doesn't
/// clear it, and losing it would quietly shrink the offline library.
struct CatalogueStore: Sendable {
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("catalogue", isDirectory: true)
    }

    func load(serverId: UUID) -> Catalogue.Snapshot? {
        guard let data = try? Data(contentsOf: file(serverId)) else { return nil }
        return try? JSONDecoder().decode(Catalogue.Snapshot.self, from: data)
    }

    func save(_ snapshot: Catalogue.Snapshot, serverId: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: file(serverId), options: .atomic)
    }

    func remove(serverId: UUID) {
        try? FileManager.default.removeItem(at: file(serverId))
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(_ serverId: UUID) -> URL {
        directory.appendingPathComponent("\(serverId.uuidString).json")
    }
}

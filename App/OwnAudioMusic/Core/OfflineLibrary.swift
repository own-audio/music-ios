import Foundation
import MusicLibrary

/// The library for screens with no server to ask: the downloads, or with "whole library" chosen
/// the server's catalogue kept on the phone. Only the active server's, the same scope as the
/// online screens.
extension AppModel {
    /// The catalogue, when the listener wants the whole library offline and it has been synced.
    private var wholeLibrary: Catalogue? {
        offlineShowsWholeLibrary ? activeCatalogue : nil
    }

    private var downloadedOnActiveServer: [DownloadManager.DownloadedTrack] {
        guard let serverId = activeServerId else { return [] }
        return downloads.tracks.values.filter { TrackID.parse($0.trackId)?.serverId == serverId }
    }

    /// In album order: artist, album, disc, track.
    var offlineSongs: [Song] {
        if let wholeLibrary { return wholeLibrary.songs }
        return downloadedOnActiveServer.map(\.song).sorted(by: Catalogue.albumOrder)
    }

    /// One album per album id among the downloads, newest download first.
    var offlineAlbumsByDownloadDate: [Album] {
        let grouped = Dictionary(grouping: downloadedOnActiveServer) { $0.song.albumId ?? $0.song.album ?? "" }
        return grouped.compactMap { id, items -> (Album, Date)? in
            guard !id.isEmpty, let first = items.first?.song else { return nil }
            let album = Album(
                id: first.albumId ?? id, name: first.album ?? "", artist: first.artist,
                artistId: first.artistId, songCount: items.count,
                duration: items.compactMap(\.song.duration).reduce(0, +),
                coverArt: first.coverArt ?? first.albumId, year: nil
            )
            return (album, items.map(\.downloadedAt).max() ?? .distantPast)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    var offlineAlbums: [Album] {
        if let wholeLibrary { return wholeLibrary.albums }
        return offlineAlbumsByDownloadDate.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var offlineArtists: [Artist] {
        if let wholeLibrary { return wholeLibrary.artists }
        let albums = offlineAlbums
        let grouped = Dictionary(grouping: albums) { $0.artistId ?? $0.artist ?? "" }
        return grouped.compactMap { id, albums -> Artist? in
            guard !id.isEmpty, let name = albums.first?.artist else { return nil }
            return Artist(id: id, name: name, albumCount: albums.count)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var offlineGenres: [Genre] {
        if let wholeLibrary { return wholeLibrary.genres }
        let songs = downloadedOnActiveServer.map(\.song)
        let grouped = Dictionary(grouping: songs) { $0.genre ?? "" }
        return grouped.compactMap { name, songs -> Genre? in
            guard !name.isEmpty else { return nil }
            return Genre(id: name, name: name, albumCount: Set(songs.compactMap(\.albumId)).count, songCount: songs.count)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func offlineAlbums(artist: Artist) -> [Album] {
        if let wholeLibrary { return wholeLibrary.albums(artist: artist) }
        return offlineAlbums.filter { $0.artistId == artist.id || ($0.artistId == nil && $0.artist == artist.name) }
    }

    /// The whole album from the catalogue whichever library is shown, so an album never opened
    /// before still lists all its songs (the ones not downloaded greyed out).
    func offlineSongs(album: Album) -> [Song] {
        if let songs = activeCatalogue?.songs(album: album), !songs.isEmpty { return songs }
        return offlineSongs.filter { $0.albumId == album.id }
    }

    func offlineSongs(genre: String) -> [Song] {
        offlineSongs.filter { $0.genre == genre }
    }

    func offlineAlbums(genre: String) -> [Album] {
        let ids = Set(offlineSongs(genre: genre).compactMap(\.albumId))
        return offlineAlbums.filter { ids.contains($0.id) }
    }

    /// Downloaded playlists, in the form the playlist screens take.
    var offlinePlaylists: [Playlist] {
        guard let serverId = activeServerId else { return [] }
        return downloads.collections.values
            .filter { $0.kind == .playlist && $0.serverId == serverId }
            .map { Playlist(id: $0.itemId, name: $0.name, comment: nil, owner: nil, songCount: $0.trackIds.count, duration: nil, coverArt: $0.coverArt) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A downloaded playlist's songs that are on the phone, in its order.
    func offlineSongs(playlistId: String) -> [Song]? {
        guard let serverId = activeServerId,
              let collection = downloads.collections[DownloadManager.collectionId(kind: .playlist, serverId: serverId, itemId: playlistId)]
        else { return nil }
        return downloads.songs(in: collection).map(\.song)
    }

    /// Matches in title, artist and album among the downloads.
    func offlineSearch(_ text: String) -> SearchResult {
        let matches = { (value: String?) in value?.localizedCaseInsensitiveContains(text) ?? false }
        return SearchResult(
            artists: offlineArtists.filter { matches($0.name) },
            albums: offlineAlbums.filter { matches($0.name) || matches($0.artist) },
            songs: offlineSongs.filter { matches($0.title) || matches($0.artist) || matches($0.album) }
        )
    }

    /// Whether a song can play right now: always online, only when downloaded offline.
    func isPlayable(_ song: Song) -> Bool {
        guard isOffline else { return true }
        guard let id = compositeId(song.id) else { return false }
        return downloads.isDownloaded(id)
    }
}

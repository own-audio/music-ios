import CarPlay
import MusicEngine
import MusicLibrary
import UIKit

/// The car's screen. It runs in the same process as the phone UI and drives the same model and
/// player, so playback started here shows on the phone and the lock screen, and the other way
/// round. The Now Playing screen is the system's own template.
///
/// Lists are short on purpose: CarPlay is for a glance and a tap. Downloads come first among
/// the library entries because a car often has no signal.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var model: AppModel { AppModel.shared }

    private static var maxItems: Int { CarPlayContent.maxItems }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        interfaceController.setRootTemplate(CPListTemplate(title: Self.title, sections: []), animated: false) { _, _ in }
        Task {
            // CarPlay can start the app without the phone UI ever appearing.
            if !model.hasLoaded { await model.load() }
            showRoot()
            followServer()
        }
    }

    /// A server added or chosen on the phone while the car is connected shows here too.
    private func followServer() {
        withObservationTracking {
            _ = model.activeServerId
            _ = model.servers.count
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.interfaceController != nil else { return }
                self.showRoot()
                self.followServer()
            }
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
    }

    private static let title = "own.music"

    // MARK: - Root

    private func showRoot() {
        let entries = CarPlayContent.rootEntries(hasServer: model.activeSource != nil)
        guard !entries.isEmpty else {
            let item = CPListItem(text: String(localized: "Add a server on your iPhone"), detailText: nil)
            item.isEnabled = false
            interfaceController?.setRootTemplate(
                CPListTemplate(title: Self.title, sections: [CPListSection(items: [item])]), animated: true
            ) { _, _ in }
            return
        }
        let items = entries.map { entry -> CPListItem in
            let item = CPListItem(text: entry.title, detailText: nil, image: UIImage(systemName: entry.symbol))
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                Task {
                    switch entry {
                    case .recentlyPlayed: await self?.pushAlbums(.recentlyPlayed, title: entry.title)
                    case .recentlyAdded: await self?.pushAlbums(.newest, title: entry.title)
                    case .downloads: self?.pushDownloads()
                    case .playlists: await self?.pushPlaylists()
                    case .artists: await self?.pushArtists()
                    case .favorites: await self?.pushFavorites()
                    }
                    completion()
                }
            }
            return item
        }
        let root = CPListTemplate(title: model.activeServer?.displayName ?? Self.title, sections: [CPListSection(items: items)])
        interfaceController?.setRootTemplate(root, animated: true) { _, _ in }
    }

    // MARK: - Lists

    private func pushAlbums(_ type: AlbumSort, title: String) async {
        guard let client = model.activeSource,
              let albums = await loading({ try await client.albums(type, limit: Self.maxItems) }) else { return }
        push(title: title, items: albums.map { album in
            listItem(album.displayName, detail: album.artist, artwork: album.coverArt ?? album.id) { [weak self] in
                await self?.playAlbum(album)
            }
        }, emptyText: String(localized: "Nothing here yet"))
    }

    private func pushPlaylists() async {
        guard let client = model.activeSource, let playlists = await loading({ try await client.playlists() }) else { return }
        push(title: String(localized: "Playlists"), items: playlists.prefix(Self.maxItems).map { playlist in
            listItem(playlist.name, detail: songCountText(playlist.songCount), artwork: playlist.coverArt) { [weak self] in
                guard let songs = await self?.loading({ try await client.playlist(id: playlist.id).songs }) else { return }
                self?.play(songs, containerId: "playlist:\(playlist.id)")
            }
        }, emptyText: String(localized: "No playlists"))
    }

    private func pushArtists() async {
        guard let client = model.activeSource, let artists = await loading({ try await client.artists() }) else { return }
        push(title: String(localized: "Artists"), items: artists.prefix(Self.maxItems).map { artist in
            let item = CPListItem(text: artist.name, detailText: nil)
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                Task {
                    await self?.pushArtist(artist)
                    completion()
                }
            }
            return item
        }, emptyText: String(localized: "No artists"))
    }

    private func pushArtist(_ artist: Artist) async {
        guard let client = model.activeSource, let albums = await loading({ try await client.albums(artistId: artist.id) }) else { return }
        push(title: artist.name, items: albums.prefix(Self.maxItems).map { album in
            listItem(album.displayName, detail: album.year.map(String.init), artwork: album.coverArt ?? album.id) { [weak self] in
                await self?.playAlbum(album)
            }
        }, emptyText: String(localized: "No albums"))
    }

    private func pushFavorites() async {
        guard let client = model.activeSource, let starred = await loading({ try await client.favorites() }) else { return }
        let songs = starred.songs
        let items = CarPlayContent.favoriteRows(songs: songs.count, albums: starred.albums).map { row -> CPListItem in
            switch row {
            case .songs(let count):
                listItem(String(localized: "Favorite Songs"), detail: songCountText(count), artwork: nil, symbol: "star.fill") { [weak self] in
                    self?.play(songs, containerId: "favorites")
                }
            case .album(let album):
                listItem(album.displayName, detail: album.artist, artwork: album.coverArt ?? album.id) { [weak self] in
                    await self?.playAlbum(album)
                }
            }
        }
        push(title: String(localized: "Favorites"), items: items, emptyText: String(localized: "No favorites"))
    }

    /// From the download index alone, so it works with no signal.
    private func pushDownloads() {
        let downloads = model.downloads
        let loose = downloads.looseTracks
        let rows = CarPlayContent.downloadRows(collections: Array(downloads.collections.values), looseSongs: loose.count)
        let items = rows.map { row -> CPListItem in
            switch row {
            case .looseSongs(let count):
                let item = CPListItem(text: String(localized: "Downloaded Songs"), detailText: songCountText(count), image: UIImage(systemName: "music.note"))
                item.handler = { [weak self] _, completion in
                    self?.model.play(downloaded: loose)
                    self?.showNowPlaying()
                    completion()
                }
                return item
            case .collection(let collection):
                let item = CPListItem(text: collection.name, detailText: collection.artist)
                item.handler = { [weak self] _, completion in
                    let songs = downloads.songs(in: collection)
                    self?.model.play(downloaded: songs, containerId: collection.id)
                    self?.showNowPlaying()
                    completion()
                }
                loadArtwork(for: item, artworkId: collection.coverArt.map { TrackID.make(serverId: collection.serverId, itemId: $0) })
                return item
            }
        }
        push(title: String(localized: "Downloads"), items: items, emptyText: String(localized: "Nothing downloaded"))
    }

    // MARK: - Helpers

    /// The answer, or `nil` after saying on the car's screen why there is none: an empty list
    /// or a tap that does nothing can't tell a driver "no signal" from "nothing there".
    private func loading<T>(_ work: () async throws -> T) async -> T? {
        do {
            return try await work()
        } catch {
            let alert = CPAlertTemplate(
                titleVariants: [error.userMessage],
                actions: [CPAlertAction(title: String(localized: "OK"), style: .cancel) { [weak self] _ in
                    self?.interfaceController?.dismissTemplate(animated: true) { _, _ in }
                }]
            )
            interfaceController?.presentTemplate(alert, animated: true) { _, _ in }
            return nil
        }
    }

    private func playAlbum(_ album: Album) async {
        guard let client = model.activeSource, let songs = await loading({ try await client.album(id: album.id).songs }) else { return }
        play(songs, containerId: "album:\(album.id)")
    }

    private func play(_ songs: [Song], containerId: String) {
        model.play(songs, containerId: containerId)
        showNowPlaying()
    }

    /// A tapped row should visibly start something, not leave the driver on the list.
    private func showNowPlaying() {
        guard interfaceController?.topTemplate !== CPNowPlayingTemplate.shared else { return }
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true) { _, _ in }
    }

    private func push(title: String, items: [CPListItem], emptyText: String) {
        interfaceController?.pushTemplate(CarPlayContent.listTemplate(title: title, items: items, emptyText: emptyText), animated: true) { _, _ in }
    }

    /// The row appears at once; its cover fills in when loaded.
    private func listItem(
        _ text: String, detail: String?, artwork coverId: String?, symbol: String? = nil,
        action: @escaping () async -> Void
    ) -> CPListItem {
        let item = CPListItem(text: text, detailText: detail, image: symbol.flatMap { UIImage(systemName: $0) })
        item.handler = { _, completion in
            Task {
                await action()
                completion()
            }
        }
        loadArtwork(for: item, artworkId: model.artworkId(coverId))
        return item
    }

    private func loadArtwork(for item: CPListItem, artworkId: String?) {
        guard let artworkId else { return }
        let covers = model.covers
        Task {
            if let image = await covers.image(artworkId: artworkId, size: 120) { item.setImage(image) }
        }
    }
}

import Foundation
import MusicEngine
import MusicLibrary

/// The ways in from outside the app: the widget's links, Siri, and the widget's snapshot. Shaped like the podcasts app's `Platform.swift`.
extension AppModel {
    /// `ownmusic://resume`, `ownmusic://play/album/<id>`, `ownmusic://play/playlist/<id>` or
    /// `ownmusic://player`. True when the player should open.
    func open(_ url: URL) async -> Bool {
        if url.scheme == WidgetSnapshot.scheme, url.host() == "player" { return engine.currentTrack != nil }
        guard let link = WidgetSnapshot.link(from: url) else { return false }
        switch link.kind {
        case .resume:
            return await continueListening()
        case .album, .playlist:
            guard let id = link.id else { return false }
            return await playLink(kind: link.kind, id: id)
        }
    }

    /// What is in the player, else the queue from before the relaunch. False with nothing to play.
    @discardableResult
    func continueListening() async -> Bool {
        if engine.currentTrack != nil {
            if !engine.isPlaying { engine.togglePlayPause() }
            return true
        }
        guard lastQueue != nil else { return false }
        await playLastQueue()
        return engine.currentTrack != nil
    }

    /// Plays an album or playlist named by its composite id (`TrackID`), from the active server.
    func playLink(kind: WidgetSnapshot.Entry.Kind, id: String) async -> Bool {
        guard let (serverId, itemId) = TrackID.parse(id), serverId == activeServerId, let source = activeSource else {
            actionError = String(localized: "That is on another server. Switch to it in Settings first.")
            return false
        }
        do {
            let songs = switch kind {
            case .playlist: try await source.playlist(id: itemId).songs
            default: try await source.album(id: itemId).songs
            }
            play(songs, containerId: "\(kind.rawValue):\(itemId)")
            return !songs.isEmpty
        } catch {
            actionError = error.userMessage
            return false
        }
    }

    /// Writes what the Recently Played widget shows: where you left off, then the albums played
    /// last on the active server. `fetch` asks the server again; otherwise the albums from the
    /// last time are kept and only the first entry follows the player.
    func refreshWidget(fetch: Bool = false) async {
        var entries: [WidgetSnapshot.Entry] = []
        var used: [String: Data] = [:]
        let current = engine.currentTrack ?? lastQueue?.current
        if let track = current {
            var cover: Data?
            if let artworkId = track.artworkId { cover = await widgetCover(artworkId, used: &used) }
            entries.append(.init(id: track.id, kind: .resume, title: track.title, subtitle: track.artist ?? "", cover: cover))
        }
        if fetch, let serverId = activeServerId, let source = activeSource, !isOffline,
           let albums = try? await source.albums(.recentlyPlayed, limit: 4) {
            var recent: [WidgetSnapshot.Entry] = []
            for album in albums {
                let artworkId = TrackID.make(serverId: serverId, itemId: album.coverArt ?? album.id)
                recent.append(.init(
                    id: TrackID.make(serverId: serverId, itemId: album.id), kind: .album, title: album.displayName,
                    subtitle: album.artist ?? "", cover: await widgetCover(artworkId, used: &used)
                ))
            }
            widgetAlbums = recent
            widgetCovers = used
        } else {
            // The albums' pictures from last time are still shown, so they stay; a few songs'
            // covers more at most, until the next fetch starts over.
            widgetCovers.merge(used) { $1 }
            if widgetCovers.count > 16 { widgetCovers = used }
        }
        entries += widgetAlbums.filter { $0.title != current?.album }
        WidgetSnapshot(entries: Array(entries.prefix(4)), at: Date()).save()
    }

    /// A cover as the widget's small JPEG, encoded once per picture: a song change within an
    /// album used to decode and encode the same cover again.
    private func widgetCover(_ artworkId: String, used: inout [String: Data]) async -> Data? {
        if let data = widgetCovers[artworkId] ?? used[artworkId] {
            used[artworkId] = data
            return data
        }
        let data = await covers.data(artworkId: artworkId, size: 160)
        if let data { used[artworkId] = data }
        return data
    }
}

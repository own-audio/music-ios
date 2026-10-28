import MusicLibrary
import SwiftUI

struct AlbumDetailView: View {
    @Environment(AppModel.self) private var model
    let album: Album
    @State private var state: LoadState<(album: Album, songs: [Song])> = .loading
    @State private var isAddingToPlaylist = false
    @State private var isChoosingCover = false
    @State private var identify: IdentifyRequest?
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        List {
            Section {
                header
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            LoadStateView(state: state, retry: load) { loaded in
                let discs = Dictionary(grouping: loaded.songs) { $0.discNumber ?? 1 }
                if discs.count > 1 {
                    ForEach(discs.keys.sorted(), id: \.self) { disc in
                        Section("Disc \(disc)") {
                            songRows(discs[disc] ?? [], all: loaded.songs)
                        }
                    }
                } else {
                    songRows(loaded.songs, all: loaded.songs)
                }
                Text(songsSummary(loaded.songs))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle(album.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if sizeClass == .regular, let id = model.compositeId(album.id) {
                // On the iPad the tab bar shares the top bar: three buttons there were folded
                // into an overflow menu, with the album's menu a level below them.
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section {
                            favoriteButton(id)
                            downloadMenuItem
                        }
                        albumMenuItems(id)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
                    .accessibilityIdentifier("album.more")
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    CollectionDownloadButton(
                        model: model,
                        collectionId: collectionId,
                        isEnabled: songs?.isEmpty == false
                    ) {
                        if case .loaded(let loaded) = state { model.download(album: loaded.album, songs: loaded.songs) }
                    }
                }
                if let id = model.compositeId(album.id) {
                    ToolbarItem(placement: .topBarTrailing) {
                        favoriteButton(id)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            albumMenuItems(id)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("More")
                    }
                }
            }
        }
        .sheet(isPresented: $isAddingToPlaylist) {
            AddToPlaylistSheet(songIds: songs?.map(\.id) ?? [])
        }
        .identifyStarter($identify)
        .artworkPicker(isPresented: $isChoosingCover) { .songs(songs ?? [], albumId: album.id) }
        .task { await load() }
    }

    private var collectionId: String? {
        model.activeServerId.map { DownloadManager.collectionId(kind: .album, serverId: $0, itemId: album.id) }
    }

    private func favoriteButton(_ id: String) -> some View {
        let starred = model.isFavorite(id)
        return Button {
            Haptics.selection()
            model.perform { try await model.toggleFavorite(id, kind: .album) }
        } label: {
            if sizeClass == .regular {
                Label(starred ? "Unfavorite Album" : "Favorite Album", systemImage: starred ? "star.fill" : "star")
            } else {
                Image(systemName: starred ? "star.fill" : "star")
            }
        }
        .accessibilityLabel(starred ? "Unfavorite Album" : "Favorite Album")
        .accessibilityIdentifier("album.star")
    }

    /// The iPad's menu entry for what `CollectionDownloadButton` shows on the iPhone.
    @ViewBuilder private var downloadMenuItem: some View {
        if let collectionId, let progress = model.downloads.progress(of: collectionId) {
            if progress.done == progress.total {
                Button(role: .destructive) {
                    model.downloads.remove(collectionId: collectionId)
                } label: {
                    Label("Remove Download", systemImage: "trash")
                }
            } else {
                Button {} label: {
                    Label("Downloading \(progress.done) of \(progress.total)", systemImage: "arrow.down.circle.dotted")
                }
                .disabled(true)
            }
        } else {
            Button {
                if case .loaded(let loaded) = state { model.download(album: loaded.album, songs: loaded.songs) }
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .disabled(songs?.isEmpty != false)
        }
    }

    @ViewBuilder
    private func albumMenuItems(_ id: String) -> some View {
        if let songs, !songs.isEmpty {
            Button {
                model.enqueue(songs, next: true)
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .accessibilityIdentifier("album.playNext")
            Button {
                model.enqueue(songs, next: false)
            } label: {
                Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
            .accessibilityIdentifier("album.addToQueue")
        }
        if model.capabilities.contains(.ratings) {
            RatingMenu(rating: model.ratings[id]) { rating in
                model.perform { try await model.setRating(id, kind: .album, rating: rating) }
            }
        }
        if model.capabilities.contains(.instantMix), !model.isOffline {
            Button {
                model.playInstantMix(itemId: album.id)
            } label: {
                Label("Instant Mix", systemImage: "wand.and.stars")
            }
        }
        Button {
            isAddingToPlaylist = true
        } label: {
            Label("Add Album to Playlist…", systemImage: "text.badge.plus")
        }
        .disabled(songs?.isEmpty ?? true)
        if model.artwork != nil, !model.isOffline, songs?.contains(where: { model.sharing(of: $0)?.isMine == true }) == true {
            Button {
                isChoosingCover = true
            } label: {
                Label("Choose Album Cover…", systemImage: "photo")
            }
        }
        // The listener's own songs on it, shared or kept to themselves together.
        if model.household != nil, !model.isOffline, let mine = songs?.filter({ model.sharing(of: $0)?.isMine == true }), !mine.isEmpty {
            if mine.allSatisfy({ model.sharing(of: $0) == .shared }) {
                Button {
                    model.setShared(mine, false)
                } label: {
                    Label("Stop Sharing My Songs", systemImage: "person")
                }
            } else {
                Button {
                    model.setShared(mine, true)
                } label: {
                    Label("Share My Songs with the Family", systemImage: "person.2")
                }
            }
        }
        if IdentifyAccess.shared.server(model) != nil, songs?.contains(where: { model.sharing(of: $0)?.isMine != false }) ?? true {
            Button {
                identify = .album(id: album.id, label: album.displayName)
            } label: {
                Label("Identify Album", systemImage: "waveform.badge.magnifyingglass")
            }
        }
    }

    private var header: some View {
        VStack(spacing: Theme.Spacing.md) {
            CoverArtView(artworkId: model.artworkId(album.coverArt ?? album.id), pointSize: 240)
                .frame(width: 240, height: 240)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover))
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
            VStack(spacing: Theme.Spacing.xs) {
                Text(album.displayName)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let artist = album.artist {
                    if let artistId = album.artistId {
                        // A `NavigationLink` inside a `List` becomes a full-width row with a
                        // chevron; hidden behind the text, the text stays a centred link.
                        Text(artist)
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .background {
                                NavigationLink(value: Route.artist(Artist(id: artistId, name: artist))) {
                                    EmptyView()
                                }
                                .opacity(0)
                            }
                            .accessibilityAddTraits(.isLink)
                    } else {
                        Text(artist).font(.title3).foregroundStyle(.secondary)
                    }
                }
                if let year = album.year {
                    Text(String(year)).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            PlayShuffleButtons(isEnabled: songs?.isEmpty == false) {
                if let songs { model.play(songs, containerId: "album:\(album.id)") }
            } shuffle: {
                if let songs { model.play(songs, shuffled: true, containerId: "album:\(album.id)") }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.sm)
    }

    private var songs: [Song]? {
        if case .loaded(let loaded) = state { loaded.songs } else { nil }
    }

    private func songRows(_ songs: [Song], all: [Song]) -> some View {
        ForEach(songs) { song in
            Button {
                Haptics.impact(.light)
                model.play(all, startSongId: song.id, containerId: "album:\(album.id)")
            } label: {
                SongRow(song: song)
            }
            .buttonStyle(.plain)
            // On the row itself: after `songActions` it would name the row's ⋯ button too.
            .accessibilityIdentifier("album.song.\(song.title)")
            .songActions(song)
        }
    }

    private func load() async {
        guard let client = model.activeSource else { return }
        do {
            let loaded = try await client.album(id: album.id)
            model.learn(songs: loaded.songs)
            model.learn(albums: [loaded.album])
            state = .loaded(loaded)
        } catch {
            // Never opened online: the catalogue on the phone, or at least the downloaded songs.
            let songs = model.offlineSongs(album: album)
            state = songs.isEmpty ? .failed(error.userMessage) : .loaded((album, songs))
        }
    }
}

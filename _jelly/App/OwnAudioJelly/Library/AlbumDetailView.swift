import JellyfinKit
import SwiftUI

struct AlbumDetailView: View {
    @Environment(AppModel.self) private var model
    let album: Album
    @State private var state: LoadState<(album: Album, songs: [Song])> = .loading
    @State private var isAddingToPlaylist = false

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
            ToolbarItem(placement: .topBarTrailing) {
                CollectionDownloadButton(
                    collectionId: model.activeServerId.map { DownloadManager.collectionId(kind: .album, serverId: $0, itemId: album.id) },
                    isEnabled: songs?.isEmpty == false
                ) {
                    if case .loaded(let loaded) = state { model.download(album: loaded.album, songs: loaded.songs) }
                }
            }
            if let id = model.compositeId(album.id) {
                ToolbarItem(placement: .topBarTrailing) {
                    let favorite = model.isFavorite(id)
                    Button {
                        Haptics.selection()
                        model.perform { try await model.toggleFavorite(id) }
                    } label: {
                        Image(systemName: favorite ? "heart.fill" : "heart")
                    }
                    .accessibilityLabel(favorite ? "Remove Album from Favorites" : "Add Album to Favorites")
                    .accessibilityIdentifier("album.favorite")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            model.playInstantMix(itemId: album.id)
                        } label: {
                            Label("Instant Mix", systemImage: "wand.and.stars")
                        }
                        .disabled(model.isOffline)
                        Button {
                            isAddingToPlaylist = true
                        } label: {
                            Label("Add Album to Playlist…", systemImage: "text.badge.plus")
                        }
                        .disabled(songs?.isEmpty ?? true)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
                }
            }
        }
        .sheet(isPresented: $isAddingToPlaylist) {
            AddToPlaylistSheet(songIds: songs?.map(\.id) ?? [])
        }
        .task { await load() }
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
            .songActions(song)
            .accessibilityIdentifier("album.song.\(song.title)")
        }
    }

    private func load() async {
        guard let client = model.activeClient else { return }
        do {
            let loaded = try await client.album(id: album.id)
            model.learn(songs: loaded.songs)
            model.learn(albums: [loaded.album])
            state = .loaded(loaded)
        } catch {
            // Never opened online, but some of it is downloaded: show those.
            let downloaded = model.offlineSongs(albumId: album.id)
            state = downloaded.isEmpty ? .failed(error.userMessage) : .loaded((album, downloaded))
        }
    }
}

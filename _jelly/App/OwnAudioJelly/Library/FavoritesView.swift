import JellyfinKit
import SwiftUI

/// Everything marked as a favorite on the server, split into songs, albums and artists.
struct FavoritesView: View {
    private enum Kind: Hashable { case songs, albums, artists }

    @Environment(AppModel.self) private var model
    @State private var state: LoadState<FavoritesResult> = .loading
    @State private var kind: Kind = .songs

    var body: some View {
        LoadStateView(state: state, retry: load) { favorites in
            List {
                Picker("Show", selection: $kind) {
                    Text("Songs (\(favorites.songs.count))").tag(Kind.songs)
                    Text("Albums (\(favorites.albums.count))").tag(Kind.albums)
                    Text("Artists (\(favorites.artists.count))").tag(Kind.artists)
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)

                switch kind {
                case .songs: songs(favorites.songs)
                case .albums: albums(favorites.albums)
                case .artists: artists(favorites.artists)
                }
            }
            .listStyle(.plain)
        }
        .navigationTitle("Favorites")
        .refreshable { await load() }
        .task { await load() }
    }

    @ViewBuilder
    private func songs(_ songs: [Song]) -> some View {
        if songs.isEmpty {
            empty("No favorite songs", hint: "Long-press a song and choose Add to Favorites.")
        } else {
            PlayShuffleButtons(isEnabled: true) {
                model.play(songs, containerId: "favorites")
            } shuffle: {
                model.play(songs, shuffled: true, containerId: "favorites")
            }
            .listRowSeparator(.hidden)
            ForEach(songs) { song in
                Button {
                    Haptics.impact(.light)
                    model.play(songs, startSongId: song.id, containerId: "favorites")
                } label: {
                    SongRow(song: song, showsCover: true)
                }
                .buttonStyle(.plain)
                .songActions(song)
            }
        }
    }

    @ViewBuilder
    private func albums(_ albums: [Album]) -> some View {
        if albums.isEmpty {
            empty("No favorite albums", hint: "Tap the heart on an album.")
        } else {
            ForEach(albums) { album in
                NavigationLink(value: Route.album(album)) {
                    HStack(spacing: Theme.Spacing.md) {
                        CoverArtView(artworkId: model.artworkId(album.coverArt ?? album.id), pointSize: 56)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(album.displayName).lineLimit(1)
                            Text(album.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func artists(_ artists: [Artist]) -> some View {
        if artists.isEmpty {
            empty("No favorite artists", hint: "Tap the heart on an artist.")
        } else {
            ForEach(artists) { artist in
                NavigationLink(value: Route.artist(artist)) {
                    HStack(spacing: Theme.Spacing.md) {
                        ArtistImage(artist: artist, size: 44)
                        Text(artist.name)
                    }
                }
            }
        }
    }

    private func empty(_ title: LocalizedStringKey, hint: LocalizedStringKey) -> some View {
        ContentUnavailableView(title, systemImage: "heart", description: Text(hint))
            .listRowSeparator(.hidden)
    }

    private func load() async {
        guard let client = model.activeClient else { return }
        do {
            let favorites = try await client.favorites()
            model.learn(songs: favorites.songs)
            model.learn(albums: favorites.albums)
            model.learn(artists: favorites.artists)
            state = .loaded(favorites)
        } catch {
            state = .failed(error.userMessage)
        }
    }
}

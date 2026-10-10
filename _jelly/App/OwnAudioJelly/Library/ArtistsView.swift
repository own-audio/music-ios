import JellyfinKit
import SwiftUI

struct ArtistsView: View {
    @Environment(AppModel.self) private var model
    @State private var state: LoadState<[Artist]> = .loading
    @State private var filter = ""

    var body: some View {
        LoadStateView(state: state, retry: load) { artists in
            let shown = filter.isEmpty ? artists : artists.filter { $0.name.localizedCaseInsensitiveContains(filter) }
            if artists.isEmpty {
                ContentUnavailableView("No Artists", systemImage: "music.mic")
            } else {
                List(shown) { artist in
                    NavigationLink(value: Route.artist(artist)) {
                        HStack(spacing: Theme.Spacing.md) {
                            ArtistImage(artist: artist, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(artist.name).lineLimit(1)
                                Text(albumCountText(artist.albumCount ?? 0))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .searchable(text: $filter, prompt: "Filter Artists")
            }
        }
        .navigationTitle("Artists")
        .refreshable { await load() }
        .task(id: model.isOffline) { await load() }
    }

    private func load() async {
        if model.isOffline {
            state = .loaded(model.offlineArtists)
            return
        }
        guard let client = model.activeClient else { return }
        do {
            let artists = try await client.artists()
            model.learn(artists: artists)
            state = .loaded(artists)
        } catch {
            state = .failed(error.userMessage)
        }
    }
}

/// An artist's picture where the server has one, a circle with an icon otherwise.
struct ArtistImage: View {
    @Environment(AppModel.self) private var model
    let artist: Artist
    let size: CGFloat

    var body: some View {
        Group {
            if let imageId = artist.imageId {
                CoverArtView(artworkId: model.artworkId(imageId), pointSize: size)
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            Circle().fill(Color(.secondarySystemFill))
            Image(systemName: "music.mic").foregroundStyle(.tertiary)
        }
    }
}

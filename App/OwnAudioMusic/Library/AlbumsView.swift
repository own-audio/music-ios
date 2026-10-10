import MusicLibrary
import SwiftUI

/// Every album, in one of the server's list orders, loaded a page at a time.
struct AlbumsView: View {
    @Environment(AppModel.self) private var model
    @State private var type: AlbumSort
    @State private var state: LoadState<[Album]> = .loading
    @State private var isLoadingMore = false
    @State private var reachedEnd = false

    private static let pageSize = 60
    /// The orders the server can list in.
    private var choices: [AlbumSort] { model.activeSource?.albumSorts ?? [.name] }

    init(initialType: AlbumSort) {
        _type = State(initialValue: initialType)
    }

    var body: some View {
        LoadStateView(state: state, retry: reload) { albums in
            if albums.isEmpty {
                ContentUnavailableView(
                    type == .favorites ? "No Favorites" : "No Albums",
                    systemImage: type == .favorites ? "star" : "square.stack"
                )
            } else {
                ScrollView {
                    AlbumGrid(albums: albums) { loadMore() }
                        .padding(.vertical, Theme.Spacing.md)
                    if isLoadingMore { ProgressView().padding() }
                }
            }
        }
        .navigationTitle(type == .favorites ? "Favorites" : "Albums")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $type) {
                        ForEach(choices, id: \.self) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .accessibilityIdentifier("albums.sort")
            }
        }
        .refreshable { await reload() }
        .task(id: "\(type.rawValue)|\(model.isOffline)") { await reload() }
    }

    private func reload() async {
        if model.isOffline {
            reachedEnd = true
            state = .loaded(offlineAlbums)
            return
        }
        guard let client = model.activeSource else { return }
        reachedEnd = false
        do {
            let page = try await client.albums(type, limit: Self.pageSize)
            reachedEnd = page.count < Self.pageSize || type == .random
            state = .loaded(page)
        } catch {
            state = .failed(error.userMessage)
        }
    }

    /// The downloaded albums, in the closest order to the chosen one.
    private var offlineAlbums: [Album] {
        switch type {
        case .artist:
            model.offlineAlbums.sorted { ($0.artist ?? "").localizedStandardCompare($1.artist ?? "") == .orderedAscending }
        case .newest, .recentlyPlayed:
            model.offlineAlbumsByDownloadDate
        case .random:
            model.offlineAlbums.shuffled()
        case .favorites:
            model.offlineAlbums.filter { model.compositeId($0.id).map(model.isFavorite) ?? false }
        default:
            model.offlineAlbums
        }
    }

    private func loadMore() {
        guard !isLoadingMore, !reachedEnd, case .loaded(let albums) = state, let client = model.activeSource else { return }
        isLoadingMore = true
        Task {
            defer { isLoadingMore = false }
            guard let page = try? await client.albums(type, limit: Self.pageSize, offset: albums.count) else { return }
            // A server can repeat an album across pages if the library changed in between, and
            // some lists come in one piece whatever the offset (Jellyfin's recently played):
            // a page with nothing new is the end.
            let known = Set(albums.map(\.id))
            let fresh = page.filter { !known.contains($0.id) }
            reachedEnd = page.count < Self.pageSize || fresh.isEmpty
            state = .loaded(albums + fresh)
        }
    }
}

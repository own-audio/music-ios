import MusicLibrary
import SwiftUI

/// Concerts: whole shows recorded as one song each, a chapter per song of the show. Shown only
/// for servers that keep them (own.audio); newest first.
struct ConcertsView: View {
    @Environment(AppModel.self) private var model
    @State private var state: LoadState<[Album]> = .loading

    var body: some View {
        LoadStateView(state: state, retry: load) { concerts in
            if concerts.isEmpty {
                ContentUnavailableView(
                    "No Concerts", systemImage: "ticket",
                    description: Text("A whole concert in one file, with a chapter where each song starts, shows up here.")
                )
            } else {
                ScrollView {
                    AlbumGrid(albums: concerts)
                        .padding(.vertical, Theme.Spacing.md)
                }
                .accessibilityIdentifier("concerts.grid")
            }
        }
        .navigationTitle("Concerts")
        .refreshable { await load() }
        .task(id: model.isOffline) { await load() }
    }

    private func load() async {
        do {
            state = .loaded(try await model.concerts())
        } catch {
            state = .failed(error.userMessage)
        }
    }
}

import JellyfinKit
import SwiftUI

extension View {
    /// Favorite, instant mix, add to a playlist, download, on a long press of any song. `removeFromPlaylist` adds a remove action, for a playlist the listener owns.
    func songActions(_ song: Song, removeFromPlaylist: (() -> Void)? = nil) -> some View {
        modifier(SongActions(song: song, removeFromPlaylist: removeFromPlaylist))
    }
}

private struct SongActions: ViewModifier {
    @Environment(AppModel.self) private var model
    let song: Song
    let removeFromPlaylist: (() -> Void)?
    @State private var isAddingToPlaylist = false

    func body(content: Content) -> some View {
        let id = model.compositeId(song.id)
        content
            .contextMenu {
                if let id {
                    let favorite = model.isFavorite(id)
                    Button {
                        model.perform { try await model.toggleFavorite(id) }
                    } label: {
                        Label(favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: favorite ? "heart.slash" : "heart")
                    }
                }
                if !model.isOffline {
                    Button {
                        model.playInstantMix(itemId: song.id)
                    } label: {
                        Label("Instant Mix", systemImage: "wand.and.stars")
                    }
                }
                Button {
                    isAddingToPlaylist = true
                } label: {
                    Label("Add to Playlist…", systemImage: "text.badge.plus")
                }
                if let id {
                    if model.downloads.isDownloaded(id) {
                        Button(role: .destructive) {
                            model.downloads.remove(trackId: id)
                        } label: {
                            Label("Remove Download", systemImage: "trash")
                        }
                    } else {
                        Button {
                            model.download(songs: [song])
                        } label: {
                            Label("Download", systemImage: "arrow.down.circle")
                        }
                    }
                }
                if let removeFromPlaylist {
                    Button(role: .destructive, action: removeFromPlaylist) {
                        Label("Remove from Playlist", systemImage: "minus.circle")
                    }
                }
            }
            .sheet(isPresented: $isAddingToPlaylist) {
                AddToPlaylistSheet(songIds: [song.id])
            }
    }
}

/// Pick a playlist, or make a new one, for the given songs.
struct AddToPlaylistSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let songIds: [String]
    @State private var state: LoadState<[Playlist]> = .loading
    @State private var isNaming = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            LoadStateView(state: state, retry: load) { playlists in
                List {
                    Button {
                        newName = ""
                        isNaming = true
                    } label: {
                        Label("New Playlist…", systemImage: "plus")
                    }
                    ForEach(playlists) { playlist in
                        Button {
                            add(to: playlist)
                        } label: {
                            HStack {
                                Text(playlist.name).foregroundStyle(.primary)
                                Spacer()
                                Text("\(playlist.songCount)").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("New Playlist", isPresented: $isNaming) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { create() }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await load() }
    }

    /// Every playlist the server lists for this user; it refuses a write it doesn't allow, and
    /// that error is shown.
    private func load() async {
        guard let client = model.activeClient else { return }
        do {
            state = .loaded(try await client.playlists())
        } catch {
            state = .failed(error.userMessage)
        }
    }

    private func add(to playlist: Playlist) {
        guard let client = model.activeClient else { return }
        Haptics.impact(.light)
        model.perform { try await client.addToPlaylist(id: playlist.id, songIds: songIds) }
        dismiss()
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let client = model.activeClient else { return }
        Haptics.impact(.light)
        model.perform { try await client.createPlaylist(name: name, songIds: songIds) }
        dismiss()
    }
}

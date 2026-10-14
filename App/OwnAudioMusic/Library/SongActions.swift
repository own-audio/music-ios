import MusicLibrary
import SwiftUI

extension View {
    /// Star, rate and add to a playlist, on a long press of any song. `removeFromPlaylist` adds a remove action, for a playlist the listener owns.
    func songActions(_ song: Song, removeFromPlaylist: (() -> Void)? = nil) -> some View {
        modifier(SongActions(song: song, removeFromPlaylist: removeFromPlaylist))
    }
}

private struct SongActions: ViewModifier {
    @Environment(AppModel.self) private var model
    let song: Song
    let removeFromPlaylist: (() -> Void)?
    @State private var isAddingToPlaylist = false
    @State private var isUndoingIdentify = false
    @State private var isIdentifying = false
    @State private var isChoosingCover = false

    func body(content: Content) -> some View {
        let id = model.compositeId(song.id)
        HStack(spacing: Theme.Spacing.sm) {
            content
            // The same actions as a long press, where people look for them.
            Menu {
                menuItems(id)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("More")
            .accessibilityIdentifier("song.more")
        }
        .contextMenu { menuItems(id) }
        .artworkPicker(isPresented: $isChoosingCover) { .songs([song], albumId: nil) }
        .confirmationDialog("Put this song back as its file says, with no MusicBrainz match?", isPresented: $isUndoingIdentify, titleVisibility: .visible) {
            Button("Undo Identify", role: .destructive) {
                guard let client = IdentifyAccess.shared.server(model)?.client else { return }
                let trackId = song.id
                model.perform { try await undoIdentify(client, trackId) }
            }
        }
        .sheet(isPresented: $isAddingToPlaylist) {
            AddToPlaylistSheet(songIds: [song.id])
        }
        .sheet(isPresented: $isIdentifying) {
            if let client = IdentifyAccess.shared.server(model)?.client {
                let trackId = song.id
                RecordingPicker(
                    songTitle: song.title,
                    songArtist: song.artist,
                    songAlbum: song.album,
                    durationSecs: song.duration,
                    search: { try await client.searchRecordings(track: trackId, $0) },
                    choose: { recording, release in
                        try await client.identify(track: trackId, recording: recording, release: release)
                    }
                )
            }
        }
    }

    @ViewBuilder
    private func menuItems(_ id: String?) -> some View {
        if let id {
            let starred = model.isFavorite(id)
            Button {
                model.perform { try await model.toggleFavorite(id, kind: .song) }
            } label: {
                Label(starred ? "Unfavorite" : "Favorite", systemImage: starred ? "star.slash" : "star")
            }
            if model.capabilities.contains(.ratings) {
                RatingMenu(rating: model.ratings[id]) { rating in
                    model.perform { try await model.setRating(id, kind: .song, rating: rating) }
                }
            }
        }
        if model.capabilities.contains(.instantMix), !model.isOffline {
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
        if model.artwork != nil, !model.isOffline, model.sharing(of: song)?.isMine == true {
            Button {
                isChoosingCover = true
            } label: {
                Label("Choose Cover…", systemImage: "photo")
            }
        }
        // Only one's own songs; "private" means not shared, never locked.
        if model.household != nil, !model.isOffline, let sharing = model.sharing(of: song), sharing.isMine {
            if sharing == .shared {
                Button {
                    model.setShared([song], false)
                } label: {
                    Label("Stop Sharing", systemImage: "person")
                }
            } else {
                Button {
                    model.setShared([song], true)
                } label: {
                    Label("Share with the Family", systemImage: "person.2")
                }
            }
        }
        // The server identifies only its owner's songs; on anyone else's it could only fail.
        if let identify = IdentifyAccess.shared.server(model), model.sharing(of: song)?.isMine != false {
            if identify.searches {
                Button {
                    isIdentifying = true
                } label: {
                    Label("Identify…", systemImage: "magnifyingglass")
                }
            }
            Button {
                isUndoingIdentify = true
            } label: {
                Label("Undo Identify…", systemImage: "arrow.uturn.backward")
            }
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
}

/// One to five stars, or none.
struct RatingMenu: View {
    let rating: Int?
    let set: (Int) -> Void

    var body: some View {
        Menu {
            ForEach((1...5).reversed(), id: \.self) { value in
                Button {
                    set(value)
                } label: {
                    if rating == value {
                        Label(String(repeating: "★", count: value), systemImage: "checkmark")
                    } else {
                        Text(String(repeating: "★", count: value))
                    }
                }
            }
            if rating != nil {
                Button("Clear Rating", role: .destructive) { set(0) }
            }
        } label: {
            Label(rating.map { String(localized: "Rating: \(String(repeating: "★", count: $0))") } ?? String(localized: "Rate"), systemImage: "star.leadinghalf.filled")
        }
    }
}

/// Pick one of the listener's own playlists, or make a new one, for the given songs.
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

    /// Only the listener's own playlists can be added to.
    private func load() async {
        guard let client = model.activeSource else { return }
        do {
            let username = model.activeServer?.auth.username
            let all = try await client.playlists()
            // A server that doesn't send `owner` per the spec gets every playlist offered; it
            // will refuse a write it doesn't allow, and that error is shown.
            state = .loaded(all.filter { $0.owner == nil || $0.owner == username })
        } catch {
            state = .failed(error.userMessage)
        }
    }

    private func add(to playlist: Playlist) {
        Haptics.impact(.light)
        model.perform { try await model.addToPlaylist(playlist.id, songIds: songIds) }
        dismiss()
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let client = model.activeSource else { return }
        Haptics.impact(.light)
        model.perform { try await client.createPlaylist(name: name, songIds: songIds) }
        dismiss()
    }
}

import MusicLibrary
import SwiftUI

struct PlaylistsView: View {
    @Environment(AppModel.self) private var model
    @State private var state: LoadState<[Playlist]> = .loading
    @State private var isNaming = false
    @State private var newName = ""
    @State private var smart: [SmartPlaylistInfo] = []
    @State private var presets: [SmartPresetInfo] = []
    @State private var newSmart: SmartRuleEditor.Draft?

    private var smartSource: (any SmartPlaylistSource)? { model.activeSource as? any SmartPlaylistSource }
    private var hasSmart: Bool { !smart.isEmpty || !presets.isEmpty }

    var body: some View {
        LoadStateView(state: state, retry: load) { playlists in
            if playlists.isEmpty, !hasSmart {
                ContentUnavailableView(
                    "No Playlists", systemImage: "music.note.list",
                    description: Text("Make one with +, or add songs to a new one from any song's menu.")
                )
            } else {
                List {
                    if hasSmart { smartSections }
                    Section {
                        ForEach(playlists) { playlist in
                            playlistRow(playlist)
                        }
                    } header: {
                        if hasSmart { Text("Playlists") }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Playlists")
        .toolbar {
            if smartSource != nil, hasSmart {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newSmart = .init(existingId: nil, name: "", rule: SmartRule(), shared: false)
                    } label: {
                        Image(systemName: "wand.and.stars")
                    }
                    .accessibilityLabel("New Smart Playlist")
                    .accessibilityIdentifier("playlists.newSmart")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newName = ""
                    isNaming = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New Playlist")
                .accessibilityIdentifier("playlists.new")
            }
        }
        .sheet(item: $newSmart) { draft in
            SmartRuleEditor(draft: draft) { _ in Task { await load() } }
        }
        .alert("New Playlist", isPresented: $isNaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { create() }
        }
        .refreshable { await load() }
        .task(id: model.isOffline) { await load() }
    }

    @ViewBuilder
    private var smartSections: some View {
        if !smart.isEmpty {
            Section("Smart Playlists") {
                ForEach(smart) { item in
                    NavigationLink(value: Route.smart(.saved(item))) {
                        smartRow(item.name, subtitle: item.isShared ? String(localized: "Shared with the household") : nil)
                    }
                }
            }
        }
        if !presets.isEmpty {
            Section("Ready-Made") {
                ForEach(presets) { preset in
                    NavigationLink(value: Route.smart(.preset(preset))) {
                        smartRow(preset.localizedName, subtitle: preset.summary)
                    }
                    .accessibilityIdentifier("playlists.preset.\(preset.slug)")
                }
            }
        }
    }

    private func smartRow(_ name: String, subtitle: String?) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "wand.and.stars")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 56, height: 56)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        NavigationLink(value: Route.playlist(playlist)) {
            HStack(spacing: Theme.Spacing.md) {
                CoverArtView(artworkId: model.artworkId(playlist.coverArt), pointSize: 56)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name).lineLimit(1)
                    Text(subtitle(playlist))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func subtitle(_ playlist: Playlist) -> String {
        let songs = songCountText(playlist.songCount)
        guard let owner = playlist.owner, owner != model.activeServer?.auth.username else { return songs }
        return String(localized: "\(songs) · by \(owner)")
    }

    private func load() async {
        guard let client = model.activeSource else { return }
        // Smart playlists where the server has them; one without answers an error, and none show.
        if let smartSource, !model.isOffline {
            async let saved = try? smartSource.smartPlaylists()
            async let ready = try? smartSource.smartPresets()
            smart = await saved ?? []
            presets = await ready ?? []
        } else {
            smart = []
            presets = []
        }
        do {
            state = .loaded(try await client.playlists())
        } catch {
            let downloaded = model.offlinePlaylists
            state = downloaded.isEmpty ? .failed(error.userMessage) : .loaded(downloaded)
        }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let client = model.activeSource else { return }
        model.perform {
            try await client.createPlaylist(name: name, songIds: [])
            await load()
        }
    }
}

struct PlaylistDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var playlist: Playlist
    @State private var state: LoadState<[Song]> = .loading
    @State private var isRenaming = false
    @State private var newName = ""
    @State private var isConfirmingDelete = false

    init(playlist: Playlist) {
        _playlist = State(initialValue: playlist)
    }

    /// Edit actions only on the listener's own playlists. A server that leaves out `owner` gets
    /// them too; it refuses what it doesn't allow, and that error is shown.
    private var isOwn: Bool {
        playlist.owner == nil || playlist.owner == model.activeServer?.auth.username
    }

    var body: some View {
        List {
            Section {
                header
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            LoadStateView(state: state, retry: load) { songs in
                // Rows are keyed by position: a playlist can hold the same song twice.
                ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                    Button {
                        Haptics.impact(.light)
                        model.play(songs, startSongId: song.id, containerId: "playlist:\(playlist.id)")
                    } label: {
                        SongRow(song: song, showsCover: true)
                    }
                    .buttonStyle(.plain)
                    .songActions(song, removeFromPlaylist: isOwn ? { remove(at: index) } : nil)
                }
                .onDelete(perform: isOwn ? { offsets in offsets.forEach(remove(at:)) } : nil)
                if !songs.isEmpty {
                    Text(songsSummary(songs))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                CollectionDownloadButton(
                    collectionId: model.activeServerId.map { DownloadManager.collectionId(kind: .playlist, serverId: $0, itemId: playlist.id) },
                    isEnabled: songs?.isEmpty == false
                ) {
                    if let songs { model.download(playlist: playlist, songs: songs) }
                }
            }
            if isOwn {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            newName = playlist.name
                            isRenaming = true
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            isConfirmingDelete = true
                        } label: {
                            Label("Delete Playlist", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Edit Playlist")
                }
            }
        }
        .alert("Rename Playlist", isPresented: $isRenaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { rename() }
        }
        .confirmationDialog("Delete \"\(playlist.name)\"?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) { delete() }
        } message: {
            Text("This deletes it on the server, for every app that uses it.")
        }
        .task { await load() }
    }

    private var header: some View {
        VStack(spacing: Theme.Spacing.md) {
            CoverArtView(artworkId: model.artworkId(playlist.coverArt), pointSize: 200)
                .frame(width: 200, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover))
            Text(playlist.name).font(.title2.bold()).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let comment = playlist.comment, !comment.isEmpty {
                Text(comment).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            PlayShuffleButtons(isEnabled: songs?.isEmpty == false) {
                if let songs { model.play(songs, containerId: "playlist:\(playlist.id)") }
            } shuffle: {
                if let songs { model.play(songs, shuffled: true, containerId: "playlist:\(playlist.id)") }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.sm)
    }

    private var songs: [Song]? {
        if case .loaded(let songs) = state { songs } else { nil }
    }

    private func load() async {
        guard let client = model.activeSource else { return }
        do {
            let loaded = try await client.playlist(id: playlist.id)
            playlist = loaded.playlist
            model.learn(songs: loaded.songs)
            state = .loaded(loaded.songs)
        } catch {
            if let downloaded = model.offlineSongs(playlistId: playlist.id), !downloaded.isEmpty {
                state = .loaded(downloaded)
            } else {
                state = .failed(error.userMessage)
            }
        }
    }

    /// Removes one entry (by position on Subsonic, by the entry's own id on Jellyfin), then
    /// reloads: positions shift, and the server is the authority.
    private func remove(at index: Int) {
        guard let client = model.activeSource, var songs else { return }
        guard songs.indices.contains(index) else { return }
        let entry = PlaylistEntry(index: index, entryId: songs[index].playlistEntryId)
        songs.remove(at: index)
        state = .loaded(songs)
        model.perform {
            defer { Task { await load() } }
            try await client.removeFromPlaylist(id: playlist.id, entries: [entry])
        }
    }

    private func rename() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let client = model.activeSource else { return }
        model.perform {
            try await client.renamePlaylist(id: playlist.id, to: name)
            await load()
        }
    }

    private func delete() {
        guard let client = model.activeSource else { return }
        model.perform {
            try await client.deletePlaylist(id: playlist.id)
            dismiss()
        }
    }
}

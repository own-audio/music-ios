import MusicLibrary
import SwiftUI

/// A smart playlist to open: a saved one, or one of the server's ready-made rules.
enum SmartTarget: Hashable {
    case saved(SmartPlaylistInfo)
    case preset(SmartPresetInfo)

    var name: String {
        switch self {
        case .saved(let p): p.name
        case .preset(let p): p.localizedName
        }
    }
}

extension SmartPresetInfo {
    /// The server names its presets in English; the app's own words where it knows the slug.
    var localizedName: String {
        switch slug {
        case "forgotten-favourites": String(localized: "Forgotten Favorites")
        case "new-in-the-library": String(localized: "New in the Library")
        case "back-in-rotation": String(localized: "Back in Rotation")
        case "what-the-family-plays": String(localized: "What the Family Plays")
        case "genre-station": String(localized: "Genre Station")
        default: name
        }
    }

    var summary: String? {
        switch slug {
        case "forgotten-favourites": String(localized: "Songs you made favorites but haven't played for a year.")
        case "new-in-the-library": String(localized: "Added in the last 30 days.")
        case "back-in-rotation": String(localized: "Rated four stars or more, not heard for two months.")
        case "what-the-family-plays": String(localized: "What others in the household play and you haven't yet.")
        case "genre-station": String(localized: "Up to 100 songs of one genre, no artist twice in a row.")
        default: nil
        }
    }

    /// A station needs its genre chosen before it can play.
    var needsGenre: Bool { slug == "genre-station" }
}

/// What a smart playlist holds now — a new draw each time it opens — with what can be done
/// with it: play it, edit the rule, keep it as an ordinary playlist, delete it.
struct SmartPlaylistView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var target: SmartTarget
    @State private var state: LoadState<SmartResult> = .loading
    @State private var genre: String?
    @State private var genres: [String] = []
    @State private var editing: SmartRuleEditor.Draft?
    @State private var isConfirmingDelete = false
    @State private var savedAsPlaylist = false

    init(target: SmartTarget) {
        _target = State(initialValue: target)
    }

    private var source: (any SmartPlaylistSource)? { model.activeSource as? any SmartPlaylistSource }

    private var saved: SmartPlaylistInfo? {
        if case .saved(let p) = target { p } else { nil }
    }

    private var preset: SmartPresetInfo? {
        if case .preset(let p) = target { p } else { nil }
    }

    private var result: SmartResult? {
        if case .loaded(let r) = state { r } else { nil }
    }

    var body: some View {
        List {
            Section {
                header
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            if preset?.needsGenre == true, genre == nil {
                Section {
                    genrePicker
                }
            } else {
                LoadStateView(state: state, retry: load) { result in
                    if result.songs.isEmpty {
                        ContentUnavailableView(
                            "Nothing Fits Right Now", systemImage: "wand.and.stars",
                            description: Text("Nothing in the library fits this rule at the moment. A wider rule gives more to choose from.")
                        )
                        .listRowSeparator(.hidden)
                    } else {
                        ForEach(Array(result.songs.enumerated()), id: \.offset) { _, song in
                            Button {
                                Haptics.impact(.light)
                                model.play(result.songs, startSongId: song.id, containerId: containerId)
                            } label: {
                                SongRow(song: song, showsCover: true)
                            }
                            .buttonStyle(.plain)
                            .songActions(song)
                        }
                        Text(summary(result))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                            .accessibilityIdentifier("smart.summary")
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(target.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(item: $editing) { draft in
            SmartRuleEditor(draft: draft) { savedInfo in
                target = .saved(savedInfo)
                Task { await load() }
            }
        }
        .confirmationDialog("Delete \"\(target.name)\"?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete Smart Playlist", role: .destructive) { delete() }
        } message: {
            Text(saved?.isShared == true
                 ? String(localized: "It is shared with the household: it goes for everyone. Playlists made from it stay.")
                 : String(localized: "Playlists made from it stay."))
        }
        .alert("Saved as a Playlist", isPresented: $savedAsPlaylist) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("It's among your playlists, as this rule chose it just now. It won't change from here on.")
        }
        .task { await load() }
    }

    private var containerId: String {
        switch target {
        case .saved(let p): "smart:\(p.id)"
        case .preset(let p): "smart-preset:\(p.slug)"
        }
    }

    private var header: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)
                .frame(width: 160, height: 160)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.cover))
                .accessibilityHidden(true)
            Text(target.name).font(.title2.bold()).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if preset?.needsGenre == true, let genre {
                Button {
                    self.genre = nil
                } label: {
                    Label(genre, systemImage: "guitars")
                }
                .buttonStyle(.bordered)
            }
            PlayShuffleButtons(isEnabled: result?.songs.isEmpty == false) {
                if let result { model.play(result.songs, containerId: containerId) }
            } shuffle: {
                if let result { model.play(result.songs, shuffled: true, containerId: containerId) }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.sm)
    }

    private var explanation: String {
        if let preset, let summary = preset.summary { return summary }
        if saved?.isShared == true {
            return String(localized: "Chosen anew each time, from your own listening. Shared with the household: everyone gets their own selection.")
        }
        return String(localized: "Chosen anew each time, from your own listening.")
    }

    private var genrePicker: some View {
        Group {
            Text("Choose a genre")
                .font(.headline)
            ForEach(genres, id: \.self) { name in
                Button(name) {
                    genre = name
                    Task { await load() }
                }
            }
        }
        .task {
            guard genres.isEmpty, let source = model.activeSource else { return }
            genres = ((try? await source.genres()) ?? []).map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("New Selection")
            .accessibilityIdentifier("smart.reload")
            .disabled(preset?.needsGenre == true && genre == nil)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let saved {
                    if saved.isMine {
                        Button {
                            editing = .init(existingId: saved.id, name: saved.name, rule: saved.rule, shared: saved.isShared)
                        } label: {
                            Label("Edit Rule", systemImage: "slider.horizontal.3")
                        }
                    }
                    Button {
                        freeze(saved)
                    } label: {
                        Label("Save as Playlist", systemImage: "music.note.list")
                    }
                    if saved.isMine {
                        Button(role: .destructive) {
                            isConfirmingDelete = true
                        } label: {
                            Label("Delete Smart Playlist", systemImage: "trash")
                        }
                    }
                } else if let preset {
                    Button {
                        editing = .init(existingId: nil, name: genre.map { "\(preset.localizedName): \($0)" } ?? preset.localizedName, rule: rule(for: preset), shared: false)
                    } label: {
                        Label("Save as Smart Playlist", systemImage: "wand.and.stars")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Smart Playlist Actions")
            .accessibilityIdentifier("smart.actions")
        }
    }

    private func rule(for preset: SmartPresetInfo) -> SmartRule {
        var rule = preset.rule
        if let genre { rule.filters.genres = .init(include: [genre.lowercased()]) }
        return rule
    }

    private func summary(_ result: SmartResult) -> String {
        let songs = songsSummary(result.songs)
        guard result.candidates > result.songs.count else { return songs }
        return String(localized: "\(songs), chosen from \(result.candidates) that fit")
    }

    private func load() async {
        guard let source else { return }
        state = .loading
        do {
            let result: SmartResult
            switch target {
            case .saved(let p): result = try await source.resolve(smartPlaylistId: p.id)
            case .preset(let p): result = try await source.resolve(rule(for: p))
            }
            model.learn(songs: result.songs)
            state = .loaded(result)
        } catch {
            state = .failed(error.userMessage)
        }
    }

    private func freeze(_ saved: SmartPlaylistInfo) {
        guard let source else { return }
        model.perform {
            try await source.freezeSmartPlaylist(id: saved.id, name: nil)
            savedAsPlaylist = true
        }
    }

    private func delete() {
        guard let saved, let source else { return }
        model.perform {
            try await source.deleteSmartPlaylist(id: saved.id)
            dismiss()
        }
    }
}

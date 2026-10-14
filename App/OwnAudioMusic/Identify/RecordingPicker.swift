import OwnAudioKit
import SwiftUI

/// Pick the MusicBrainz recording a song really is: from what was already found, from a search
/// in your own words — a file's tags are often what is wrong ("Track 02", a typo) — or from a
/// pasted musicbrainz.org link.
struct RecordingPicker: View {
    /// The song as the library has it now.
    let songTitle: String
    let songArtist: String?
    let songAlbum: String?
    let durationSecs: Int?
    /// What is known before searching: a proposal's alternatives, or nothing.
    var initial: () async throws -> [RecordingCandidate] = { [] }
    let search: (RecordingSearch) async throws -> [RecordingCandidate]
    /// Applies the choice: a recording id or link, and the release it was found on.
    let choose: (_ recording: String, _ release: String?) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var link = ""
    @State private var results: [RecordingCandidate] = []
    @State private var searched = false
    /// The album left out because nothing was found on it.
    @State private var widened: String?
    @State private var searching = false
    @State private var choosing: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ClearableField("Title", text: $title, id: "picker.title")
                    ClearableField("Artist", text: $artist, id: "picker.artist")
                    ClearableField("Album", text: $album, id: "picker.album")
                    Button {
                        Task { await runSearch() }
                    } label: {
                        HStack {
                            Label("Search MusicBrainz", systemImage: "magnifyingglass")
                            if searching { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(searching || isBlank)
                    .accessibilityIdentifier("picker.search")
                } header: {
                    Text("Search")
                } footer: {
                    Text("Correct the words if the tags are wrong — a typo, \u{201C}Track 02\u{201D}, the artist in the title.")
                }

                Section {
                    if results.isEmpty {
                        Text(searched ? "Nothing found. Try fewer or other words." : "Nothing found yet.")
                            .foregroundStyle(.secondary)
                    } else if let widened {
                        Text("Nothing on \u{201C}\(widened)\u{201D}: these are from other releases.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(results) { candidate in
                        Button {
                            Task { await apply(candidate.mbRecordingId, candidate.mbReleaseId, key: candidate.id) }
                        } label: {
                            CandidateRow(candidate: candidate, songSecs: durationSecs, choosing: choosing == candidate.id)
                        }
                        .disabled(choosing != nil)
                        .accessibilityIdentifier("picker.result")
                    }
                } header: {
                    Text("Recordings")
                }

                Section {
                    TextField("musicbrainz.org/recording/…", text: $link)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Use This Recording") {
                        Task { await apply(link, nil, key: "link") }
                    }
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || choosing != nil)
                } header: {
                    Text("Or Paste a Link")
                } footer: {
                    Text("A recording's link or ID from musicbrainz.org.")
                }
            }
            .navigationTitle(songTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .alert("That Didn't Work", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .task { await load() }
        }
    }

    private var isBlank: Bool {
        [title, artist, album].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func load() async {
        title = songTitle
        artist = songArtist ?? ""
        album = songAlbum ?? ""
        do {
            results = try await initial()
        } catch {
            errorMessage = identifyMessage(error)
        }
    }

    private func runSearch() async {
        searching = true
        defer { searching = false }
        let words = { (s: String) -> String? in
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        do {
            widened = nil
            results = try await search(RecordingSearch(title: words(title), artist: words(artist), album: words(album)))
            // The album is often the tag that was wrong too: with nothing on it, anywhere.
            if results.isEmpty, let onAlbum = words(album), words(title) != nil || words(artist) != nil {
                results = try await search(RecordingSearch(title: words(title), artist: words(artist), album: nil))
                if !results.isEmpty { widened = onAlbum }
            }
            searched = true
        } catch {
            errorMessage = identifyMessage(error)
        }
    }

    private func apply(_ recording: String, _ release: String?, key: String) async {
        choosing = key
        defer { choosing = nil }
        do {
            try await choose(recording.trimmingCharacters(in: .whitespaces), release)
            dismiss()
        } catch {
            errorMessage = identifyMessage(error)
        }
    }
}

private struct CandidateRow: View {
    let candidate: RecordingCandidate
    let songSecs: Int?
    let choosing: Bool

    var body: some View {
        HStack {
            CoverThumb(urls: CoverArtArchive.fronts(release: candidate.mbReleaseId, group: nil))
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title).foregroundStyle(.primary)
                Text([candidate.artist, candidate.album, candidate.year.map { String($0) }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if choosing {
                ProgressView()
            } else if let ms = candidate.durationMs {
                Text(Duration.seconds(ms / 1000).formatted(.time(pattern: .minuteSecond)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(lengthFits(ms) ? Color.secondary : Color.orange)
            }
        }
    }

    /// Within five seconds of the song's own length, as the server's matching counts it.
    private func lengthFits(_ ms: Int) -> Bool {
        guard let songSecs else { return true }
        return abs(ms / 1000 - songSecs) <= 5
    }
}

/// A text field with a ✕ that empties it: the tags fill these, and correcting one usually
/// means typing it anew.
private struct ClearableField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    let id: String

    init(_ title: LocalizedStringKey, text: Binding<String>, id: String) {
        self.title = title
        _text = text
        self.id = id
    }

    var body: some View {
        HStack {
            TextField(title, text: $text)
                .accessibilityIdentifier(id)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear")
                .accessibilityIdentifier("\(id).clear")
            }
        }
    }
}

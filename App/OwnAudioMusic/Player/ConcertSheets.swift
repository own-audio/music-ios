import MusicEngine
import MusicLibrary
import SwiftUI

/// The songs of the concert playing: tap one to hear it. Its owner can edit them.
struct ChaptersSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var engine: PlaybackEngine { model.engine }

    private var canEdit: Bool {
        guard let id = engine.currentTrack?.id else { return false }
        return model.song(forTrackId: id)?.sharing?.isMine == true
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(engine.currentChapters.enumerated()), id: \.offset) { index, chapter in
                    Button {
                        Haptics.impact(.light)
                        Task { await engine.playChapter(at: index) }
                        dismiss()
                    } label: {
                        HStack(spacing: Theme.Spacing.md) {
                            Group {
                                if index == engine.currentChapterIndex {
                                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
                                } else {
                                    Text("\(index + 1)").foregroundStyle(.secondary)
                                }
                            }
                            .font(.subheadline.monospacedDigit())
                            .frame(width: 28)
                            Text(chapter.title)
                                .foregroundStyle(.primary)
                                .fontWeight(index == engine.currentChapterIndex ? .semibold : .regular)
                            Spacer()
                            Text(ChapterTime.format(chapter.startSecs))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("chapters.row.\(index)")
                }
            }
            .listStyle(.plain)
            .navigationTitle("Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if canEdit {
                    ToolbarItem(placement: .primaryAction) {
                        NavigationLink("Edit") { ChapterEditorView() }
                            .accessibilityIdentifier("chapters.edit")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Edits the songs of the concert playing: rename, move one to where the player is, add one
/// there, delete. Saved as a whole; the server keeps them from then on, whatever the file says.
struct ChapterEditorView: View {
    private struct Row: Identifiable {
        let id = UUID()
        var title: String
        var time: String
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row] = []
    @State private var isSaving = false
    @State private var problem: String?

    private var engine: PlaybackEngine { model.engine }

    var body: some View {
        List {
            Section {
                ForEach($rows) { $row in
                    HStack(spacing: Theme.Spacing.sm) {
                        TextField("Time", text: $row.time)
                            .font(.body.monospacedDigit())
                            .keyboardType(.numbersAndPunctuation)
                            .frame(width: 80)
                            .foregroundStyle(ChapterTime.parse(row.time) == nil ? .red : .primary)
                        TextField("Song", text: $row.title)
                        Button {
                            row.time = ChapterTime.format(engine.currentTime)
                        } label: {
                            Image(systemName: "location")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Start Here")
                    }
                }
                .onDelete { rows.remove(atOffsets: $0) }
            } footer: {
                Text("The arrow sets a song's start to where the player is now.")
            }
            Section {
                Button {
                    rows.append(Row(title: "", time: ChapterTime.format(engine.currentTime)))
                } label: {
                    Label("Add a Song Here", systemImage: "plus")
                }
                .accessibilityIdentifier("chapters.add")
            }
        }
        .navigationTitle("Edit Songs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Save", action: save)
                        .accessibilityIdentifier("chapters.save")
                }
            }
        }
        .alert("Couldn't Save", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
        .onAppear {
            rows = engine.currentChapters.map { Row(title: $0.title, time: ChapterTime.format($0.startSecs)) }
        }
    }

    private func save() {
        guard let trackId = engine.currentTrack?.id else { return }
        var chapters: [SongChapter] = []
        for row in rows {
            let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let start = ChapterTime.parse(row.time) else {
                problem = String(localized: "“\(row.time)” is not a time. Write it as 9:26 or 1:02:03.")
                return
            }
            guard !title.isEmpty else {
                problem = String(localized: "Every song needs a name.")
                return
            }
            chapters.append(SongChapter(title: title, startSecs: start))
        }
        chapters.sort { $0.startSecs < $1.startSecs }
        if zip(chapters, chapters.dropFirst()).contains(where: { $0.startSecs == $1.startSecs }) {
            problem = String(localized: "Two songs start at the same time.")
            return
        }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await model.saveChapters(chapters, trackId: trackId)
                Haptics.impact(.light)
                dismiss()
            } catch {
                problem = error.userMessage
            }
        }
    }
}

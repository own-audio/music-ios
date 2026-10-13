import MusicLibrary
import SwiftUI

/// Makes or changes a smart playlist's rule, showing as it goes how many songs fit.
struct SmartRuleEditor: View {
    /// What the editor starts from.
    struct Draft: Identifiable {
        let id = UUID()
        /// Nil for a new smart playlist.
        let existingId: String?
        var name: String
        var rule: SmartRule
        var shared: Bool
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Draft
    @State private var genres: [String] = []
    @State private var matching: Int?
    @State private var isSaving = false
    @State private var errorMessage: String?
    let onSaved: (SmartPlaylistInfo) -> Void

    init(draft: Draft, onSaved: @escaping (SmartPlaylistInfo) -> Void) {
        _draft = State(initialValue: draft)
        self.onSaved = onSaved
    }

    private var source: (any SmartPlaylistSource)? { model.activeSource as? any SmartPlaylistSource }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                        .accessibilityIdentifier("smartEditor.name")
                    Toggle("Share with the Household", isOn: $draft.shared)
                } footer: {
                    Text("Shared, it is a rule rather than a list: each member gets their own selection, from what they have listened to.")
                }

                Section {
                    if let matching {
                        Label(matching == 1 ? String(localized: "1 song fits") : String(localized: "\(matching) songs fit"), systemImage: "music.note")
                            .accessibilityIdentifier("smartEditor.matching")
                    } else {
                        ProgressView()
                    }
                } footer: {
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }

                Section("Songs") {
                    NavigationLink {
                        GenreChoice(all: genres, chosen: genreBinding)
                    } label: {
                        LabeledContent("Genres", value: genreSummary)
                    }
                    .accessibilityIdentifier("smartEditor.genres")
                    Toggle("Favorites Only", isOn: optionalBool(\.starred))
                    Picker("Rating at Least", selection: $draft.rule.filters.minRating) {
                        Text("Any").tag(Int?.none)
                        ForEach(1...5, id: \.self) { stars in
                            Text(String(repeating: "★", count: stars)).tag(Int?.some(stars))
                        }
                    }
                    Picker("Not Played For", selection: $draft.rule.filters.notPlayedDays) {
                        Text("Any Time").tag(Int?.none)
                        Text("A Month").tag(Int?.some(30))
                        Text("Three Months").tag(Int?.some(90))
                        Text("Half a Year").tag(Int?.some(180))
                        Text("A Year").tag(Int?.some(365))
                    }
                    Picker("Added in the Last", selection: $draft.rule.filters.addedDays) {
                        Text("Any Time").tag(Int?.none)
                        Text("Week").tag(Int?.some(7))
                        Text("Month").tag(Int?.some(30))
                        Text("Three Months").tag(Int?.some(90))
                    }
                    Toggle("Played by Others, Not by Me", isOn: optionalBool(\.playedByOthersNotMe))
                }

                Section {
                    Toggle("Limit the Tempo", isOn: tempoOn)
                    if let bpm = draft.rule.filters.bpm, bpm.count == 2 {
                        Stepper("From \(Int(bpm[0])) BPM", value: bpmBound(0), in: 40...240, step: 5)
                        Stepper("To \(Int(bpm[1])) BPM", value: bpmBound(1), in: 40...240, step: 5)
                    }
                    Picker("Energy", selection: energyBinding) {
                        Text("Any").tag(EnergyBand.any)
                        Text("Calm").tag(EnergyBand.calm)
                        Text("Moderate").tag(EnergyBand.moderate)
                        Text("Energetic").tag(EnergyBand.energetic)
                    }
                } header: {
                    Text("Tempo and Energy")
                } footer: {
                    Text("Only songs the server has analysed have a tempo and an energy; with these set, the others are left out.")
                }

                Section("Length") {
                    Picker("Measure", selection: limitIsMinutes) {
                        Text("Songs").tag(false)
                        Text("Minutes").tag(true)
                    }
                    .pickerStyle(.segmented)
                    switch draft.rule.limit {
                    case .count(let n):
                        Stepper("\(n) songs", value: limitValue, in: 10...500, step: 10)
                    case .minutes(let m):
                        Stepper("\(m) min", value: limitValue, in: 15...1440, step: 15)
                    }
                }

                Section("Order") {
                    Picker("Order", selection: $draft.rule.sort) {
                        Text("Mixed, Favorites More Often").tag(SmartRule.Sort.weightedRandom)
                        Text("Best First").tag(SmartRule.Sort.weight)
                        Text("Longest Unplayed First").tag(SmartRule.Sort.leastRecentlyPlayed)
                        Text("Random").tag(SmartRule.Sort.random)
                    }
                    Picker("Energy Over Time", selection: $draft.rule.arc) {
                        Text("Even").tag(SmartRule.Arc.none)
                        Text("Warm Up, Steady, Cool Down").tag(SmartRule.Arc.warmupSustainCooldown)
                        Text("Building Up").tag(SmartRule.Arc.build)
                        Text("Winding Down").tag(SmartRule.Arc.unwind)
                    }
                    Stepper("At Most \(draft.rule.sequence.maxPerArtist) per Artist", value: $draft.rule.sequence.maxPerArtist, in: 1...20)
                    Toggle("Never the Same Artist Twice in a Row", isOn: $draft.rule.sequence.noConsecutiveArtist)
                }

            }
            .navigationTitle(draft.existingId == nil ? "New Smart Playlist" : "Edit Smart Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                            .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityIdentifier("smartEditor.save")
                    }
                }
            }
            .task {
                guard genres.isEmpty, let source = model.activeSource else { return }
                genres = ((try? await source.genres()) ?? []).map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            }
            .task(id: draft.rule) {
                // Asked again once the changes settle, not on every tap of a stepper.
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let source else { return }
                matching = nil
                matching = (try? await source.resolve(draft.rule))?.candidates
            }
        }
    }

    // MARK: - Bindings over the rule's optional fields

    private func optionalBool(_ path: WritableKeyPath<SmartRule.Filters, Bool?>) -> Binding<Bool> {
        Binding(get: { draft.rule.filters[keyPath: path] == true }, set: { draft.rule.filters[keyPath: path] = $0 ? true : nil })
    }

    private var genreBinding: Binding<Set<String>> {
        Binding(
            get: { Set(draft.rule.filters.genres?.include ?? []) },
            set: { draft.rule.filters.genres = $0.isEmpty ? nil : .init(include: $0.sorted()) }
        )
    }

    private var genreSummary: String {
        let chosen = draft.rule.filters.genres?.include ?? []
        switch chosen.count {
        case 0: return String(localized: "All")
        case 1: return chosen[0].capitalized
        default: return String(localized: "\(chosen.count) genres")
        }
    }

    private var tempoOn: Binding<Bool> {
        Binding(get: { draft.rule.filters.bpm != nil }, set: { draft.rule.filters.bpm = $0 ? [90, 130] : nil })
    }

    private func bpmBound(_ index: Int) -> Binding<Double> {
        Binding(
            get: { draft.rule.filters.bpm?[index] ?? 0 },
            set: { value in
                guard var bpm = draft.rule.filters.bpm else { return }
                bpm[index] = value
                if bpm[0] > bpm[1] { bpm = index == 0 ? [value, value] : [value, value] }
                draft.rule.filters.bpm = bpm
            }
        )
    }

    /// The rule's energy is a range from 0 to 1, relative to this library; three bands are
    /// what a person can choose between.
    enum EnergyBand: Hashable {
        case any, calm, moderate, energetic

        var range: [Double]? {
            switch self {
            case .any: nil
            case .calm: [0, 0.4]
            case .moderate: [0.3, 0.7]
            case .energetic: [0.6, 1]
            }
        }
    }

    private var energyBinding: Binding<EnergyBand> {
        Binding(
            get: {
                switch draft.rule.filters.energy {
                case [0, 0.4]: .calm
                case [0.3, 0.7]: .moderate
                case [0.6, 1]: .energetic
                default: .any
                }
            },
            set: { draft.rule.filters.energy = $0.range }
        )
    }

    private var limitIsMinutes: Binding<Bool> {
        Binding(
            get: { if case .minutes = draft.rule.limit { true } else { false } },
            set: { draft.rule.limit = $0 ? .minutes(60) : .count(50) }
        )
    }

    private var limitValue: Binding<Int> {
        Binding(
            get: {
                switch draft.rule.limit {
                case .count(let n): n
                case .minutes(let m): m
                }
            },
            set: { value in
                switch draft.rule.limit {
                case .count: draft.rule.limit = .count(value)
                case .minutes: draft.rule.limit = .minutes(value)
                }
            }
        )
    }

    private func save() {
        guard let source else { return }
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                let saved = if let id = draft.existingId {
                    try await source.updateSmartPlaylist(id: id, name: name, rule: draft.rule, shared: draft.shared)
                } else {
                    try await source.saveSmartPlaylist(name: name, rule: draft.rule, shared: draft.shared)
                }
                onSaved(saved)
                dismiss()
            } catch {
                errorMessage = error.userMessage
            }
        }
    }
}

/// The library's genres to tick; none ticked means all.
private struct GenreChoice: View {
    let all: [String]
    @Binding var chosen: Set<String>

    var body: some View {
        List {
            if all.isEmpty {
                ProgressView()
            }
            ForEach(all, id: \.self) { name in
                let key = name.lowercased()
                Button {
                    if chosen.contains(key) { chosen.remove(key) } else { chosen.insert(key) }
                } label: {
                    HStack {
                        Text(name).foregroundStyle(.primary)
                        Spacer()
                        if chosen.contains(key) {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
            }
        }
        .navigationTitle("Genres")
        .toolbar {
            if !chosen.isEmpty {
                Button("All") { chosen = [] }
            }
        }
    }
}

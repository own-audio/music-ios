import OwnAudioKit
import SwiftUI

/// One identify run: its progress, then what it proposes, by album, to accept or reject.
struct IdentifyRunView: View {
    let client: OwnAudioClient
    let runId: String

    enum Tab: String, CaseIterable, Identifiable {
        case review, sure, none, decided
        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .review: "To Review"
            case .sure: "Sure"
            case .none: "Not Found"
            case .decided: "Done"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var run: IdentifyRun?
    @State private var tab: Tab = .review
    @State private var proposals: [IdentifyProposal] = []
    @State private var isLoading = true
    @State private var busy = false
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var confirmRevert = false
    @State private var confirmDelete = false
    @State private var editionsFor: IdentifyProposal.Group?

    var body: some View {
        List {
            if let run {
                Section {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        IdentifyStatusBadge(status: run.status)
                        if run.isActive, run.groupsTotal > 0 {
                            ProgressView(value: Double(run.groupsDone), total: Double(run.groupsTotal))
                        }
                        Text(identifySummary(run))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    if run.status == "waiting" {
                        Text("MusicBrainz is busy. The run waits and carries on by itself.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if run.status == "failed", let error = run.error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }

                Section {
                    Picker("Show", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    if tab == .sure, !proposals.isEmpty {
                        Button {
                            act { let n = try await client.acceptSureMatches(runId); message = String(localized: "\(n) songs identified") }
                        } label: {
                            Label("Accept \(proposals.count) Sure Matches", systemImage: "checkmark.circle")
                        }
                        .disabled(busy)
                    }
                }

                if proposals.isEmpty, !isLoading {
                    Section {
                        Text(emptyText)
                            .foregroundStyle(.secondary)
                    } footer: {
                        if run.isActive { Text("Still looking — more will appear as the run goes on.") }
                    }
                }

                ForEach(groups, id: \.0.id) { group, items in
                    Section {
                        ForEach(items) { proposal in
                            ProposalRow(proposal: proposal, busy: busy, accept: {
                                act { try await client.acceptProposal(proposal.id) }
                            }, reject: {
                                act { try await client.rejectProposal(proposal.id) }
                            }, keepAlbum: { keep in
                                act { try await client.setKeepAlbum(proposal.id, keep) }
                            })
                        }
                    } header: {
                        GroupHeader(group: group, items: items, busy: busy, acceptAlbum: {
                            act { for p in acceptable(items) { try await client.acceptProposal(p.id) } }
                        }, otherEdition: { editionsFor = group })
                    }
                }
            } else if !isLoading {
                ContentUnavailableView("This run is gone", systemImage: "questionmark.circle")
            }
        }
        .overlay { if isLoading && run == nil { ProgressView() } }
        .navigationTitle(run.map { $0.scope.kind == "library" ? String(localized: "Whole library") : $0.scope.label ?? "" } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if (run?.counts.accepted ?? 0) > 0 {
                        Button("Undo Run", systemImage: "arrow.uturn.backward") { confirmRevert = true }
                    }
                    Button("Delete Run", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
            }
        }
        .confirmationDialog("Put every song this run identified back the way it was?", isPresented: $confirmRevert, titleVisibility: .visible) {
            Button("Undo Run", role: .destructive) {
                act { let n = try await client.revertIdentifyRun(runId); message = String(localized: "\(n) songs put back") }
            }
        }
        .confirmationDialog("Delete this run and its proposals? What you accepted stays.", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Run", role: .destructive) {
                Task {
                    do {
                        try await client.deleteIdentifyRun(runId)
                        dismiss()
                    } catch {
                        errorMessage = identifyMessage(error)
                    }
                }
            }
        }
        .sheet(item: $editionsFor) { group in
            EditionsSheet(client: client, group: group) { await reload() }
        }
        .alert("That Didn't Work", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .overlay(alignment: .bottom) {
            if let message {
                Text(message)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.sm)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, Theme.Spacing.lg)
                    .task {
                        try? await Task.sleep(for: .seconds(2.5))
                        self.message = nil
                    }
            }
        }
        .refreshable { await reload() }
        .task(id: tab) { await reload() }
        .task { await watch() }
    }

    private var emptyText: LocalizedStringKey {
        switch tab {
        case .review: "Nothing to review"
        case .sure: "No sure matches waiting"
        case .none: "Nothing left unfound"
        case .decided: "Nothing accepted or rejected yet"
        }
    }

    /// Proposals by album, in the server's order; an album's songs by disc and number.
    private var groups: [(IdentifyProposal.Group, [IdentifyProposal])] {
        var order: [String] = []
        var byGroup: [String: [IdentifyProposal]] = [:]
        for p in proposals {
            if byGroup[p.group.id] == nil { order.append(p.group.id) }
            byGroup[p.group.id, default: []].append(p)
        }
        return order.compactMap { id in
            guard let items = byGroup[id], let first = items.first else { return nil }
            let sorted = items.sorted {
                (($0.track.discNumber ?? 1), ($0.track.trackNumber ?? 999)) < (($1.track.discNumber ?? 1), ($1.track.trackNumber ?? 999))
            }
            return (first.group, sorted)
        }
    }

    private func act(_ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await work()
            } catch {
                errorMessage = identifyMessage(error)
            }
            await reload()
        }
    }

    private func reload() async {
        do {
            run = try await client.identifyRun(runId)
            var all: [IdentifyProposal] = []
            var cursor: String?
            repeat {
                let page = try await client.identifyProposals(runId, proposalClass: filter.proposalClass, decision: filter.decision, cursor: cursor)
                all += page.items
                cursor = page.next
            } while cursor != nil
            proposals = tab == .decided ? all.filter { $0.decision != "pending" } : all
        } catch OwnAudioError.problem(let problem) where problem.status == 404 {
            run = nil
        } catch {
            if run == nil { errorMessage = identifyMessage(error) }
        }
        isLoading = false
    }

    private var filter: (proposalClass: String?, decision: String?) {
        switch tab {
        case .review: ("review", "pending")
        case .sure: ("sure", "pending")
        case .none: ("none", "pending")
        case .decided: (nil, nil)
        }
    }

    private func watch() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await progress in IdentifyEvents.progress(client) where progress.runId == runId {
                    await reload()
                }
            }
            group.addTask {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    if await run?.isActive == true { await reload() }
                }
            }
        }
    }
}

/// Songs an album's "accept" takes: pending, with a match, and not matched to another artist —
/// that is probably a wrong match, to decide on its own.
func acceptable(_ items: [IdentifyProposal]) -> [IdentifyProposal] {
    items.filter { $0.decision == "pending" && $0.proposal != nil && !$0.reasons.contains("artist_differs") }
}

extension IdentifyProposal.Group: Identifiable {}

private struct GroupHeader: View {
    let group: IdentifyProposal.Group
    let items: [IdentifyProposal]
    let busy: Bool
    let acceptAlbum: () -> Void
    let otherEdition: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.label).lineLimit(1)
                if group.kind == "album", let match = items.first(where: { $0.proposal != nil })?.proposal, let album = match.album {
                    Text(verbatim: match.year.map { "→ \(album) (\(String($0)))" } ?? "→ \(album)")
                        .font(.caption2)
                        .lineLimit(1)
                }
            }
            Spacer()
            if group.kind == "album" {
                Menu {
                    let count = acceptable(items).count
                    if count > 1 {
                        Button("Accept All \(count) Songs", systemImage: "checkmark", action: acceptAlbum)
                    }
                    Button("Other Edition…", systemImage: "opticaldisc", action: otherEdition)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(busy)
                .accessibilityLabel("Album Actions")
            }
        }
    }
}

private struct ProposalRow: View {
    let proposal: IdentifyProposal
    let busy: Bool
    let accept: () -> Void
    let reject: () -> Void
    let keepAlbum: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(position(proposal.track.discNumber, proposal.track.trackNumber))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(proposal.track.title).lineLimit(1)
            }
            if let match = proposal.proposal {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(match.title).font(.subheadline).lineLimit(1)
                        Text([match.artist, proposal.keepAlbum ? proposal.track.album : match.album, match.year.map { String($0) }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } else {
                Text("Nothing found").font(.caption).foregroundStyle(.secondary)
            }
            if !proposal.reasons.isEmpty {
                Text(proposal.reasons.map(reasonTitle).joined(separator: " · "))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
            }
            if proposal.proposal != nil, proposal.decision == "pending",
               proposal.reasons.contains("album_differs") || proposal.keepAlbum {
                Toggle(isOn: Binding(get: { proposal.keepAlbum }, set: keepAlbum)) {
                    Text("Keep it on “\(proposal.track.album ?? "")”").font(.caption)
                }
                .disabled(busy)
            }
            if proposal.decision != "pending" {
                Text(proposal.decision == "accepted" ? "Accepted" : "Rejected")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(proposal.decision == "accepted" ? .green : .secondary)
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .leading) {
            if proposal.decision == "pending", proposal.proposal != nil {
                Button("Accept", systemImage: "checkmark", action: accept).tint(.green)
            }
        }
        .swipeActions(edge: .trailing) {
            if proposal.decision == "pending" {
                Button("Reject", systemImage: "xmark", action: reject).tint(.gray)
            }
        }
        .contextMenu {
            if proposal.decision == "pending" {
                if proposal.proposal != nil { Button("Accept", systemImage: "checkmark", action: accept) }
                Button("Reject", systemImage: "xmark", action: reject)
            }
        }
    }

    /// "1-04" for a song on a known disc, "4" without one.
    private func position(_ disc: Int?, _ track: Int?) -> String {
        guard let track else { return "" }
        guard let disc else { return String(track) }
        return "\(disc)-\(String(format: "%02d", track))"
    }

    private func reasonTitle(_ code: String) -> String {
        switch code {
        case "incomplete": String(localized: "Part of the album")
        case "partial": String(localized: "Some songs not on it")
        case "layout": String(localized: "Different numbering")
        case "duplicate": String(localized: "Two files, one track")
        case "ambiguous": String(localized: "Another match as good")
        case "album_differs": String(localized: "Other album")
        case "artist_differs": String(localized: "Other artist")
        case "weak": String(localized: "Weak match")
        case "not_found": String(localized: "Not found")
        case "not_on_release": String(localized: "Not on this edition")
        default: code
        }
    }
}

/// Another edition of an album: the releases the server already found, no new lookup.
private struct EditionsSheet: View {
    let client: OwnAudioClient
    let group: IdentifyProposal.Group
    let changed: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<IdentifyGroup> = .loading
    @State private var choosing: Int?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            LoadStateView(state: state, retry: load) { detail in
                List {
                    if detail.chosen == nil {
                        Text("No one release fits all these songs, so each was matched on its own. Pick a release to match the whole album to it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if detail.editions.isEmpty {
                        Text("No other editions were found.").foregroundStyle(.secondary)
                    }
                    ForEach(detail.editions) { edition in
                        Button {
                            Task { await choose(edition.index) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(edition.year.map { "\(edition.title) (\(String($0)))" } ?? edition.title)
                                        .foregroundStyle(.primary)
                                    Text(editionDetail(edition))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if detail.chosen == edition.index {
                                    Text("In Use").font(.caption.weight(.medium)).foregroundStyle(Color.accentColor)
                                } else if choosing == edition.index {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(detail.chosen == edition.index || choosing != nil)
                    }
                }
            }
            .navigationTitle(group.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .alert("That Didn't Work", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .task { await load() }
        }
    }

    private func editionDetail(_ edition: IdentifyGroup.Edition) -> String {
        var parts = [String(localized: "\(edition.trackCount) tracks, \(edition.matched) matched")]
        parts += edition.secondaryTypes
        if let status = edition.status, status != "Official" { parts.append(status) }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        do {
            state = .loaded(try await client.identifyGroup(group.id))
        } catch {
            state = .failed(identifyMessage(error))
        }
    }

    private func choose(_ index: Int) async {
        choosing = index
        defer { choosing = nil }
        do {
            try await client.chooseEdition(group: group.id, index: index)
            await changed()
            dismiss()
        } catch {
            errorMessage = identifyMessage(error)
        }
    }
}

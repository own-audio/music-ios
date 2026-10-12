import OwnAudioKit
import SwiftUI

/// own.audio's "identify library": the server compares the songs with MusicBrainz in the
/// background and proposes titles, albums and ids; nothing changes until they are accepted, and
/// the files themselves never change.
struct IdentifyRunsView: View {
    let client: OwnAudioClient
    /// The server charges for identifying (its `billing` module): ask before starting.
    let charges: Bool

    @State private var state: LoadState<[IdentifyRun]> = .loading
    @State private var isStarting = false
    @State private var quote: IdentifyQuote?
    @State private var errorMessage: String?
    @State private var opened: String?

    var body: some View {
        LoadStateView(state: state, retry: load) { runs in
            List {
                Section {
                    Button {
                        Task { await start() }
                    } label: {
                        HStack {
                            Label("Identify Whole Library", systemImage: "waveform.badge.magnifyingglass")
                            Spacer()
                            if isStarting { ProgressView() }
                        }
                    }
                    .disabled(isStarting)
                    .accessibilityIdentifier("identify.start")
                } footer: {
                    Text("Compares your songs with MusicBrainz in the background, then shows what it found: accept the sure matches at once, look at the rest one by one. Your files never change, and a run can be undone. MusicBrainz answers about one album a second, so a large library takes a while.")
                }

                if !runs.isEmpty {
                    Section("Runs") {
                        ForEach(runs) { run in
                            NavigationLink {
                                IdentifyRunView(client: client, runId: run.id)
                            } label: {
                                IdentifyRunRow(run: run)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Identify Library")
        .navigationDestination(item: $opened) { id in
            IdentifyRunView(client: client, runId: id)
        }
        .confirmationDialog(
            quote.map { confirmText($0) } ?? "",
            isPresented: Binding(get: { quote != nil }, set: { if !$0 { quote = nil } }),
            titleVisibility: .visible
        ) {
            Button("Start") { Task { await begin() } }
            Button("Cancel", role: .cancel) { quote = nil }
        }
        .alert("Couldn't Start Identifying", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .refreshable { await load() }
        .task { await watch() }
    }

    private func confirmText(_ quote: IdentifyQuote) -> String {
        let price = (Double(quote.chargeMicro) / 1_000_000).formatted(.currency(code: "USD").precision(.fractionLength(2...3)))
        return String(localized: "\(quote.tracks) songs to identify. This can cost up to \(price): you pay only for songs MusicBrainz finds, once per song, and correcting them later is free.")
    }

    private func load() async {
        do {
            state = .loaded(try await client.identifyRuns())
        } catch {
            if case .loaded = state { return }
            state = .failed(identifyMessage(error))
        }
    }

    /// Progress arrives as `identify` events where the server sends them; a slow poll covers
    /// older servers and a dropped connection.
    private func watch() async {
        await load()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in IdentifyEvents.progress(client) { await load() }
            }
            group.addTask {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    if await hasActiveRun { await load() }
                }
            }
        }
    }

    private var hasActiveRun: Bool {
        if case .loaded(let runs) = state { return runs.contains(where: \.isActive) }
        return false
    }

    private func start() async {
        isStarting = true
        defer { isStarting = false }
        if charges {
            do {
                let quote = try await client.identifyQuote(.library(label: nil))
                if quote.chargeMicro > 0 {
                    self.quote = quote
                    return
                }
            } catch {
                errorMessage = identifyMessage(error)
                return
            }
        }
        await begin()
    }

    private func begin() async {
        quote = nil
        do {
            let run = try await client.startIdentify(.library(label: String(localized: "Whole library")))
            await load()
            opened = run.id
        } catch {
            errorMessage = identifyMessage(error)
        }
    }
}

struct IdentifyRunRow: View {
    let run: IdentifyRun

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text(run.scope.kind == "library" ? String(localized: "Whole library") : run.scope.label ?? String(localized: "Selected songs"))
                    .lineLimit(1)
                Spacer()
                IdentifyStatusBadge(status: run.status)
            }
            if run.isActive, run.groupsTotal > 0 {
                ProgressView(value: Double(run.groupsDone), total: Double(run.groupsTotal))
            }
            Text(identifySummary(run))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct IdentifyStatusBadge: View {
    let status: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var title: String {
        switch status {
        case "queued": String(localized: "Queued")
        case "running": String(localized: "Identifying")
        case "waiting": String(localized: "Waiting")
        case "ready": String(localized: "Ready")
        case "failed": String(localized: "Failed")
        default: String(localized: "Cancelled")
        }
    }

    private var color: Color {
        switch status {
        case "ready": .green
        case "failed": .red
        case "waiting": .orange
        default: .accentColor
        }
    }
}

func identifySummary(_ run: IdentifyRun) -> String {
    String(localized: "\(run.counts.sure) sure · \(run.counts.review) to review · \(run.counts.none) not found · \(run.counts.accepted) accepted")
}

/// The server's own words for a refusal (402 when the credit is short, say), else a plain one.
func identifyMessage(_ error: Error) -> String {
    if case OwnAudioError.problem(let problem) = error, let detail = problem.detail, !detail.isEmpty {
        return detail
    }
    if case OwnAudioError.network = error { return String(localized: "Couldn't reach the server.") }
    return String(localized: "Something went wrong.")
}

enum IdentifyEvents {
    /// One element per `identify` event, until the connection ends; reconnects after a pause.
    static func progress(_ client: OwnAudioClient) -> AsyncStream<IdentifyProgress> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    do {
                        for try await event in client.events() {
                            if let progress = IdentifyProgress(event) { continuation.yield(progress) }
                        }
                    } catch {}
                    try? await Task.sleep(for: .seconds(15))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

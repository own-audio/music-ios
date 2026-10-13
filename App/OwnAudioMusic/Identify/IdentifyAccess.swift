import MusicLibrary
import OwnAudioKit
import SwiftUI

/// Whether the server in use offers "identify library" (its `identify_library` module), asked
/// once per server and remembered while the app runs. Screens show their identify actions only
/// when it does, so a server without it shows nothing broken.
@MainActor @Observable
final class IdentifyAccess {
    static let shared = IdentifyAccess()

    struct Server {
        let client: OwnAudioClient
        /// The server charges for identifying (its `billing` module): ask before starting.
        let charges: Bool
    }

    private var modules: [UUID: [String: Bool]] = [:]
    @ObservationIgnored private var asking: Set<UUID> = []

    /// The active server's identify, when it offers it. The first call for a server asks it
    /// and returns nil; screens update once the answer is in.
    func server(_ model: AppModel) -> Server? {
        guard !model.isOffline, let id = model.activeServerId,
              let client = model.ownAudioSource(serverId: id)?.client else { return nil }
        guard let known = modules[id] else {
            ask(id, client)
            return nil
        }
        guard known["identify_library"] == true else { return nil }
        return Server(client: client, charges: known["billing"] == true)
    }

    private func ask(_ id: UUID, _ client: OwnAudioClient) {
        guard !asking.contains(id) else { return }
        asking.insert(id)
        Task {
            // A failed ask is not remembered, so the next screen asks again.
            if let answer = try? await client.modules() { modules[id] = answer }
            asking.remove(id)
        }
    }
}

/// A run to start: what it covers, and how the confirmation names it.
struct IdentifyRequest: Identifiable {
    let id = UUID()
    let scope: IdentifyScope

    static func album(id: String, label: String) -> IdentifyRequest {
        IdentifyRequest(scope: IdentifyScope(kind: "album", id: id, label: label))
    }

    /// An artist is a contributor on own.audio; its id is the same through either API.
    static func artist(id: String, label: String) -> IdentifyRequest {
        IdentifyRequest(scope: IdentifyScope(kind: "artist", id: id, label: label))
    }
}

/// Puts one song back as its file says. A song never identified is not an error worth more
/// than the server's own words.
func undoIdentify(_ client: OwnAudioClient, _ trackId: String) async throws {
    do {
        try await client.undoIdentify(track: trackId)
    } catch OwnAudioError.problem(let problem) where problem.status == 409 {
        throw SourceError.server(problem.detail ?? String(localized: "This song has not been identified."))
    }
}

extension View {
    /// Starts the run in `request` when it is set — after saying the price on a server that
    /// charges — and then shows it in a sheet.
    func identifyStarter(_ request: Binding<IdentifyRequest?>) -> some View {
        modifier(IdentifyStarter(request: request))
    }
}

private struct IdentifyStarter: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var request: IdentifyRequest?
    @State private var quote: (IdentifyQuote, IdentifyRequest, OwnAudioClient)?
    @State private var started: StartedRun?
    @State private var errorMessage: String?

    struct StartedRun: Identifiable {
        let id: String
        let client: OwnAudioClient
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: request?.id) { _, new in
                guard new != nil, let request else { return }
                self.request = nil
                Task { await begin(request) }
            }
            .confirmationDialog(
                quote.map { identifyChargeText($0.0) } ?? "",
                isPresented: Binding(get: { quote != nil }, set: { if !$0 { quote = nil } }),
                titleVisibility: .visible
            ) {
                Button("Start") {
                    guard let (_, request, client) = quote else { return }
                    quote = nil
                    Task { await start(request, client) }
                }
                Button("Cancel", role: .cancel) { quote = nil }
            }
            .sheet(item: $started) { run in
                NavigationStack {
                    IdentifyRunView(client: run.client, runId: run.id)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { started = nil }
                            }
                        }
                }
            }
            .alert("Couldn't Start Identifying", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private func begin(_ request: IdentifyRequest) async {
        guard let server = IdentifyAccess.shared.server(model) else { return }
        if server.charges {
            do {
                let quote = try await server.client.identifyQuote(request.scope)
                if quote.chargeMicro > 0 {
                    self.quote = (quote, request, server.client)
                    return
                }
            } catch {
                errorMessage = identifyMessage(error)
                return
            }
        }
        await start(request, server.client)
    }

    private func start(_ request: IdentifyRequest, _ client: OwnAudioClient) async {
        do {
            let run = try await client.startIdentify(request.scope)
            started = StartedRun(id: run.id, client: client)
        } catch {
            errorMessage = identifyMessage(error)
        }
    }
}

/// "12 songs to identify. This can cost up to $0.012: …"
func identifyChargeText(_ quote: IdentifyQuote) -> String {
    let price = (Double(quote.chargeMicro) / 1_000_000).formatted(.currency(code: "USD").precision(.fractionLength(2...3)))
    return String(localized: "\(quote.tracks) songs to identify. This can cost up to \(price): you pay only for songs MusicBrainz finds, once per song, and correcting them later is free.")
}

import JellyfinKit
import SwiftUI

/// Signs in without typing a password: shows a code to approve in a Jellyfin app that is
/// already signed in, and waits for the approval.
struct QuickConnectView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let address: String
    let name: String
    /// Called once the server is saved.
    var onSignedIn: () -> Void = {}

    @State private var code: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Spacing.xl) {
                if let errorMessage {
                    ContentUnavailableView {
                        Label("Quick Connect Didn't Work", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try Again") { Task { await run() } }
                            .buttonStyle(.bordered)
                    }
                } else if let code {
                    Spacer()
                    Text("Enter this code in a Jellyfin app where you're signed in, under Quick Connect in your user settings.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Text(verbatim: code)
                        .font(.system(size: 48, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("quickConnect.code")
                    ProgressView("Waiting for approval…")
                    Spacer()
                } else {
                    ProgressView()
                }
            }
            .padding(Theme.Spacing.xl)
            .navigationTitle("Quick Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task { await run() }
    }

    /// Starts a request, then asks every few seconds whether it was approved. Leaving the screen
    /// cancels the task, and with it the waiting.
    private func run() async {
        errorMessage = nil
        code = nil
        do {
            let (host, info) = try await model.findServer(address)
            guard await JellyfinClient.isQuickConnectEnabled(host: host) else {
                errorMessage = String(localized: "Quick Connect is turned off on this server. An administrator can turn it on in the dashboard, or sign in with your password.")
                return
            }
            var request = try await JellyfinClient.startQuickConnect(host: host, clientInfo: AppModel.clientInfo)
            code = request.code
            while !request.isApproved {
                try await Task.sleep(for: .seconds(3))
                request = try await JellyfinClient.checkQuickConnect(host: host, secret: request.secret)
            }
            let session = try await JellyfinClient.finishQuickConnect(host: host, secret: request.secret, clientInfo: AppModel.clientInfo)
            try await model.save(host: host, info: info, session: session, name: name)
            Haptics.impact(.medium)
            onSignedIn()
            dismiss()
        } catch is CancellationError {
            return
        } catch let error as AddServerError {
            errorMessage = error.localizedDescription
        } catch {
            // The request expires after a few minutes; starting over gives a new code.
            errorMessage = error.userMessage
        }
    }
}

/// Which music library a server shows: one, or all of them.
struct LibraryPickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let server: ServerRecord
    @State private var state: LoadState<[MusicLibrary]> = .loading

    var body: some View {
        NavigationStack {
            List {
                LoadStateView(state: state, retry: load) { libraries in
                    row(name: String(localized: "All Music Libraries"), id: nil)
                    ForEach(libraries) { library in
                        row(name: library.name, id: library.id)
                    }
                }
            }
            .navigationTitle("Music Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private func row(name: String, id: String?) -> some View {
        Button {
            Haptics.selection()
            model.perform { try await model.setLibrary(serverId: server.id, libraryId: id) }
            dismiss()
        } label: {
            HStack {
                Text(name).foregroundStyle(.primary)
                Spacer()
                if model.servers.first(where: { $0.id == server.id })?.libraryId == id {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
    }

    private func load() async {
        let libraries = await model.musicLibraries(serverId: server.id)
        state = libraries.isEmpty ? .failed(String(localized: "Couldn't load the server's libraries.")) : .loaded(libraries)
    }
}

import SwiftUI

/// Address, username, password; checked against the server before anything is saved. Used from
/// Settings; the first run has `OnboardingView`.
struct AddServerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var name = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var isQuickConnecting = false
    @FocusState private var focus: Field?

    private enum Field { case address, username, password, name }

    /// Jellyfin allows accounts with no password, so an empty one is fine.
    private var canConnect: Bool {
        !address.trimmingCharacters(in: .whitespaces).isEmpty && !username.isEmpty && !isConnecting
    }

    var body: some View {
        Form {
            Section {
                TextField("Address", text: $address, prompt: Text("jellyfin.example.com or 192.168.1.10:8096"))
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .address)
                    .submitLabel(.next)
                    .onSubmit { focus = .username }
                    .accessibilityIdentifier("addServer.address")
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                    .accessibilityIdentifier("addServer.username")
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { if canConnect { connect() } }
                    .accessibilityIdentifier("addServer.password")
            } footer: {
                Text("Without http:// or https://, the app tries https, then http on port 8096. The password is used once to sign in and isn't stored; the app keeps the sign-in the server gives it, in this phone's Keychain.")
            }

            Section {
                TextField("Name (optional)", text: $name)
                    .focused($focus, equals: .name)
                    .accessibilityIdentifier("addServer.name")
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("addServer.error")
                }
            }

            Section {
                Button {
                    connect()
                } label: {
                    HStack {
                        Spacer()
                        if isConnecting {
                            ProgressView()
                        } else {
                            Text("Connect").bold()
                        }
                        Spacer()
                    }
                }
                .disabled(!canConnect)
                .accessibilityIdentifier("addServer.connect")
                Button {
                    isQuickConnecting = true
                } label: {
                    HStack {
                        Spacer()
                        Text("Sign In with Quick Connect")
                        Spacer()
                    }
                }
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting)
                .accessibilityIdentifier("addServer.quickConnect")
            } footer: {
                Text("Quick Connect signs in with a code you approve in a Jellyfin app where you're already signed in; no password typed here.")
            }
        }
        .navigationTitle("Add Server")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .onAppear { if address.isEmpty { focus = .address } }
        .sheet(isPresented: $isQuickConnecting) {
            QuickConnectView(address: address, name: name) { dismiss() }
        }
    }

    private func connect() {
        focus = nil
        isConnecting = true
        errorMessage = nil
        Task {
            do {
                try await model.addServer(address: address, username: username, password: password, name: name)
                Haptics.impact(.medium)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isConnecting = false
        }
    }
}

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
    @State private var appleError: String?
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
                TextField("Address", text: $address, prompt: Text("music.example.com or 192.168.1.10:4533"))
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
                Text("Works with own.audio, Navidrome and other Subsonic servers, and Jellyfin; the app finds out which. Without http:// or https://, it tries https and then http. Your sign-in stays in this phone's Keychain.\n\nown.audio: sign in with your account's email and password.")
            }

            Section {
                CanaryServerButton(address: $address)
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
                        Text("Sign In with Quick Connect (Jellyfin)")
                        Spacer()
                    }
                }
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting)
                .accessibilityIdentifier("addServer.quickConnect")
            } footer: {
                Text("Quick Connect signs in to Jellyfin with a code you approve in a Jellyfin app where you're already signed in; no password typed here.")
            }
        }
        .navigationTitle("Add Server")
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Theme.Spacing.xs) {
                AppleSignInButton(address: address, name: name, isWorking: $isConnecting, errorMessage: $appleError) { dismiss() }
                GoogleSignInButton(address: address, name: name, isWorking: $isConnecting, errorMessage: $appleError) { dismiss() }
                Text("For own.audio servers that offer it: enter the address above.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.sm)
            .background(.bar)
        }
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

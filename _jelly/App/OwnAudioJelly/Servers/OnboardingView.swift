import SwiftUI

/// The first screen: what the app is, and the one thing it needs, a server.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
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
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                header
                form
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("addServer.error")
                }
                connectButton
                Button("Sign In with Quick Connect") { isQuickConnecting = true }
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting)
                    .accessibilityIdentifier("addServer.quickConnect")
                notes
                Link(destination: URL(string: "https://github.com/own-audio/jelly-ios")!) {
                    Text("Free and open source · MPL-2.0")
                        .font(.footnote)
                }
                .padding(.top, Theme.Spacing.sm)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.xxl)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $isQuickConnecting) {
            QuickConnectView(address: address, name: name)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    private var header: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image("AppLogo")
                .resizable()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                .accessibilityHidden(true)
            Text(verbatim: "own.jelly")
                .font(.largeTitle.bold())
            Text("Your music, from your Jellyfin server.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("For Jellyfin 10.9 and later")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, Theme.Spacing.sm)
    }

    private var form: some View {
        VStack(spacing: 0) {
            row("globe") {
                TextField("Server address", text: $address, prompt: Text("jellyfin.example.com"))
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .address)
                    .submitLabel(.next)
                    .onSubmit { focus = .username }
                    .accessibilityIdentifier("addServer.address")
            }
            Divider().padding(.leading, 48)
            row("person") {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                    .accessibilityIdentifier("addServer.username")
            }
            Divider().padding(.leading, 48)
            row("key") {
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { if canConnect { connect() } }
                    .accessibilityIdentifier("addServer.password")
            }
            Divider().padding(.leading, 48)
            row("tag") {
                TextField("Name (optional)", text: $name)
                    .focused($focus, equals: .name)
                    .accessibilityIdentifier("addServer.name")
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func row<Field: View>(_ symbol: String, @ViewBuilder field: () -> Field) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            field()
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .frame(minHeight: 52)
    }

    private var connectButton: some View {
        Button {
            connect()
        } label: {
            Group {
                if isConnecting {
                    ProgressView().tint(.white)
                } else {
                    Text("Connect").bold()
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!canConnect)
        .accessibilityIdentifier("addServer.connect")
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            note("checkmark.shield", "Your password is used once to sign in and isn't stored. The app keeps the sign-in Jellyfin gives it, in this iPhone's Keychain.")
            note("network", "Without http:// or https://, the app tries https, then http on port 8096, which suits a server at home.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func note(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        Label {
            Text(text).font(.footnote).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary).font(.footnote)
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
            } catch {
                errorMessage = error.localizedDescription
            }
            isConnecting = false
        }
    }
}

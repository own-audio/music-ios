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
    @State private var appleError: String?
    @State private var isQuickConnecting = false
    @State private var isTryingDemo = false
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
                CanaryServerButton(address: $address)
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("addServer.error")
                }
                connectButton
                Button("Sign In with Quick Connect (Jellyfin)") { isQuickConnecting = true }
                    .font(.subheadline)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting)
                    .accessibilityIdentifier("addServer.quickConnect")
                VStack(spacing: Theme.Spacing.xs) {
                    AppleSignInButton(address: address, name: name, isWorking: $isConnecting, errorMessage: $appleError)
                    Text("For own.audio servers that offer it: enter the address above.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                demo
                notes
                Link(destination: URL(string: "https://github.com/own-audio/music-ios")!) {
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
            Text(verbatim: "own.audio Music")
                .font(.largeTitle.bold())
            Text("Your music, from your own server.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(verbatim: "own.audio · Navidrome · Jellyfin · Gonic · Airsonic · LMS · Ampache")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, Theme.Spacing.sm)
    }

    private var form: some View {
        VStack(spacing: 0) {
            row("globe") {
                TextField("Server address", text: $address, prompt: Text("music.example.com"))
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

    /// Someone without a server yet can still see what the app does.
    private var demo: some View {
        VStack(spacing: Theme.Spacing.xs) {
            Divider().padding(.vertical, Theme.Spacing.sm)
            Text("No server yet?")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                tryDemo()
            } label: {
                Group {
                    if isTryingDemo {
                        ProgressView()
                    } else {
                        Text("Try the Demo Library")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isConnecting || isTryingDemo)
            .accessibilityIdentifier("addServer.demo")
            Text("A shared own.audio server with sample music. Remove it in Settings when you add your own.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            note("checkmark.shield", "Your sign-in stays in this iPhone's Keychain. Subsonic servers get a one-time token made from the password; Jellyfin gives a token and the password isn't kept.")
            note("info.circle", "own.audio: sign in with your account's email and password.")
            note("network", "Without http:// or https://, the app tries https and then http, so a server at home works as typed.")
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

    private func tryDemo() {
        focus = nil
        isTryingDemo = true
        errorMessage = nil
        Task {
            do {
                try await model.addDemoServer()
                Haptics.impact(.medium)
            } catch {
                errorMessage = error.localizedDescription
            }
            isTryingDemo = false
        }
    }
}

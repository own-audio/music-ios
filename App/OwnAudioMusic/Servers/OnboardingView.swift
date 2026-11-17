import SwiftUI

/// The first screen, over the own.audio hero like Books and Podcasts: the mark, the wordmark,
/// an own.audio account for someone without a server, and the server form.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    /// Which of Apple and Google the own.audio server at the typed address takes.
    @State private var providers: (apple: Bool, google: Bool) = (false, false)
    @State private var username = ""
    @State private var password = ""
    @State private var name = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var appleError: String?
    @State private var isQuickConnecting = false
    @State private var isTryingDemo = false
    @State private var isSigningUp = false
    @FocusState private var focus: Field?

    private enum Field { case address, username, password, name }

    /// Jellyfin allows accounts with no password, so an empty one is fine.
    private var canConnect: Bool {
        !address.trimmingCharacters(in: .whitespaces).isEmpty && !username.isEmpty && !isConnecting
    }

    var body: some View {
        ZStack {
        HeroBackground()
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                header
                ownAudioAccount
                Text("Or connect your own server")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.Colors.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, -Theme.Spacing.md)
                form
                CanaryServerButton(address: $address)
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(Theme.Colors.error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("addServer.error")
                }
                connectButton
                Button("Sign In with Quick Connect (Jellyfin)") { isQuickConnecting = true }
                    .font(.subheadline)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting)
                    .accessibilityIdentifier("addServer.quickConnect")
                VStack(spacing: Theme.Spacing.xs) {
                    if providers.apple { AppleSignInButton(address: address, name: name, isWorking: $isConnecting, errorMessage: $appleError) }
                    if providers.google { GoogleSignInButton(address: address, name: name, isWorking: $isConnecting, errorMessage: $appleError) }
                    Text(providers.apple || providers.google ? "Or sign in with the Apple or Google account you use on this own.audio server." : "")
                        .font(.footnote)
                        .foregroundStyle(Theme.Colors.muted)
                        .multilineTextAlignment(.center)
                }
                // Asked once typing pauses: whether an own.audio server answers there, and which sign-ins it takes.
                .task(id: address) {
                    providers = (false, false)
                    guard address.trimmingCharacters(in: .whitespaces).count > 3 else { return }
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    let found = await model.ownAudioProviders(address: address)
                    if !Task.isCancelled { providers = found }
                }
                notes
                Link(destination: URL(string: "https://github.com/own-audio/music-ios")!) {
                    Text("Free and open source · MPL-2.0")
                        .font(.footnote)
                }
                .padding(.top, Theme.Spacing.sm)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.xxl)
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        }
        .sheet(isPresented: $isSigningUp) { SignUpView() }
        .sheet(isPresented: $isQuickConnecting) {
            QuickConnectView(address: address, name: name)
        }
        .sheet(item: model.pendingTwoFactorBinding) { _ in
            TwoFactorView()
        }
    }

    private var header: some View {
        VStack(spacing: Theme.Spacing.md) {
            OwnAudioMark.tribe(size: 120)
            RotatingWordmark()
            Text("Your music, from your own server.")
                .font(.subheadline)
                .foregroundStyle(Theme.Colors.muted)
                .multilineTextAlignment(.center)
            Text(verbatim: "own.audio · Navidrome · Jellyfin · Gonic · Airsonic · LMS · Ampache")
                .font(.footnote)
                .foregroundStyle(Theme.Colors.muted)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, Theme.Spacing.sm)
    }

    /// own.audio's hosted service first: an account there is a server, with nothing to run.
    private var ownAudioAccount: some View {
        VStack(spacing: Theme.Spacing.md) {
            VStack(spacing: Theme.Spacing.xs) {
                Text("No server? Use own.audio")
                    .font(.headline)
                Text("own.audio keeps your music for you. Upload it once and play it here.")
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.muted)
                    .multilineTextAlignment(.center)
            }
            Button {
                isSigningUp = true
            } label: {
                Text("Create an own.audio Account").bold().frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("addServer.signUp")
            Button {
                address = AppModel.ownAudioService.absoluteString
                focus = .username
            } label: {
                Text("Sign In").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("addServer.ownAudioSignIn")
            // Someone not ready for an account can still see what the app does.
            Button {
                tryDemo()
            } label: {
                if isTryingDemo { ProgressView() } else { Text("Try the Demo Library") }
            }
            .font(.subheadline.weight(.semibold))
            .disabled(isConnecting || isTryingDemo)
            .accessibilityIdentifier("addServer.demo")
            Text("Sample music on a shared own.audio server, no account needed.")
                .font(.footnote)
                .foregroundStyle(Theme.Colors.muted)
                .multilineTextAlignment(.center)
                .padding(.top, -Theme.Spacing.sm)
        }
        .padding(Theme.Spacing.lg)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.miniPlayer, style: .continuous))
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.miniPlayer, style: .continuous))
    }

    private func row<Field: View>(_ symbol: String, @ViewBuilder field: () -> Field) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.Colors.muted)
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
            note("checkmark.shield", "Your sign-in stays in this device's Keychain. Subsonic servers get a one-time token made from the password; Jellyfin gives a token and the password isn't kept.")
            note("info.circle", "own.audio: sign in with your account's email and password.")
            note("network", "Without http:// or https://, the app tries https and then http, so a server at home works as typed.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func note(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        Label {
            Text(text).font(.footnote).foregroundStyle(Theme.Colors.muted)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Theme.Colors.muted).font(.footnote)
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
            } catch where error.isTwoFactorNeeded {
                // The code sheet takes it from here.
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

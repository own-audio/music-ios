import AuthenticationServices
import SwiftUI

/// Sign in with Apple to the own.audio server whose address is typed above it. Apple's own
/// button: black on a light background, white on a dark one, as Apple asks.
struct AppleSignInButton: View {
    let address: String
    let name: String
    @Binding var isWorking: Bool
    @Binding var errorMessage: String?
    var onSignedIn: () -> Void = {}

    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SignInWithAppleButton(.signIn) { request in
            request.requestedScopes = [.fullName, .email]
        } onCompletion: { result in
            switch result {
            case .success(let authorization):
                guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                      let data = credential.identityToken, let token = String(data: data, encoding: .utf8)
                else {
                    errorMessage = String(localized: "Apple didn't return a sign-in. Try again.")
                    return
                }
                // Apple gives the name only the first time someone signs in to this app.
                let fullName = credential.fullName.map { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) }
                signIn(token: token, fullName: fullName)
            case .failure(let error):
                if (error as? ASAuthorizationError)?.code == .canceled { return }
                errorMessage = error.localizedDescription
            }
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        // The style is read once; a new identity redraws it when the appearance changes.
        .id(colorScheme)
        .frame(height: 50)
        .clipShape(Capsule())
        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
        .opacity(address.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
        .accessibilityIdentifier("addServer.apple")
    }

    private func signIn(token: String, fullName: String?) {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await model.addOwnAudioServer(address: address, appleIdentityToken: token, fullName: fullName, name: name)
                Haptics.impact(.medium)
                onSignedIn()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}

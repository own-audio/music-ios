import SwiftUI

/// The second step of an own.audio sign-in when the account has two-factor sign-in on: the six
/// digits from the authenticator app, or one of the recovery codes.
struct TwoFactorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var isChecking = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool
    /// After the server is saved.
    var onSignedIn: () -> Void = {}

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Code", text: $code)
                        .textContentType(.oneTimeCode)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.title2.monospacedDigit())
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit(check)
                        .accessibilityIdentifier("twoFactor.code")
                } footer: {
                    Text("This account asks for a second step. Enter the code your authenticator app shows for it, or one of your recovery codes.")
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("twoFactor.error")
                    }
                }
                Section {
                    Button {
                        check()
                    } label: {
                        HStack {
                            Spacer()
                            if isChecking { ProgressView() } else { Text("Sign In").bold() }
                            Spacer()
                        }
                    }
                    .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || isChecking)
                    .accessibilityIdentifier("twoFactor.signIn")
                }
            }
            .navigationTitle("Two-Factor Sign-In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.cancelTwoFactor()
                        dismiss()
                    }
                }
            }
            .onAppear { focused = true }
        }
        .interactiveDismissDisabled(isChecking)
    }

    private func check() {
        guard !code.trimmingCharacters(in: .whitespaces).isEmpty, !isChecking else { return }
        isChecking = true
        errorMessage = nil
        Task {
            do {
                try await model.finishTwoFactor(code: code)
                Haptics.impact(.medium)
                dismiss()
                onSignedIn()
            } catch {
                errorMessage = error.localizedDescription
            }
            isChecking = false
        }
    }
}

extension AppModel {
    /// For `.sheet(item:)`: dismissing the sheet drops the waiting sign-in.
    var pendingTwoFactorBinding: Binding<PendingTwoFactor?> {
        Binding(get: { self.pendingTwoFactor }, set: { if $0 == nil { self.cancelTwoFactor() } })
    }
}

extension Error {
    /// The code being asked for is the sign-in going on, not a failure to show.
    var isTwoFactorNeeded: Bool {
        guard let error = self as? AddServerError, case .twoFactorNeeded = error else { return false }
        return true
    }
}

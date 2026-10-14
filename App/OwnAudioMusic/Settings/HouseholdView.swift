import CoreImage.CIFilterBuiltins
import MusicLibrary
import SwiftUI

/// The household on an own.audio server: who is in it, an invitation for someone new (admins),
/// and joining another household with a code.
struct HouseholdView: View {
    @Environment(AppModel.self) private var model
    @State private var state: LoadState<HouseholdInfo> = .loading
    @State private var invites: [HouseholdInvite] = []
    @State private var shownInvite: HouseholdInvite?
    @State private var isCreatingInvite = false
    @State private var isAskingCode = false
    @State private var code = ""
    @State private var isConfirmingJoin = false

    var body: some View {
        LoadStateView(state: state, retry: load) { household in
            List {
                Section {
                    header(household)
                }
                .listRowBackground(Color.clear)

                Section {
                    ForEach(household.members) { member in
                        MemberRow(member: member)
                    }
                } header: {
                    Text("Members")
                } footer: {
                    Text("What you add to the library is yours. Share songs from their menu, or a whole album or playlist; everyone in the household can then play them. Smart playlists can be shared too: each member gets their own selection.")
                }

                if household.isAdmin {
                    Section {
                        Button {
                            createInvite()
                        } label: {
                            HStack {
                                Label("Invite Someone", systemImage: "person.badge.plus")
                                if isCreatingInvite {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(isCreatingInvite || model.isOffline)
                        .accessibilityIdentifier("household.invite")
                        ForEach(invites) { invite in
                            Button {
                                shownInvite = invite
                            } label: {
                                LabeledContent {
                                    if let expires = invite.expiresAt {
                                        Text(expires, format: .dateTime.day().month())
                                    }
                                } label: {
                                    Text(invite.code).font(.body.monospaced())
                                }
                            }
                            .swipeActions {
                                Button("Withdraw", role: .destructive) { withdraw(invite) }
                            }
                        }
                    } header: {
                        Text("Invitations")
                    } footer: {
                        Text("An invitation is a code for one person. They sign in to this server and enter it, or open its link.")
                    }
                }

                Section {
                    Button {
                        code = ""
                        isAskingCode = true
                    } label: {
                        Label("Join Another Household…", systemImage: "person.2.badge.key")
                    }
                    .disabled(model.isOffline)
                } footer: {
                    Text("With a code from that household's admin. You then leave this one.")
                }
            }
        }
        .navigationTitle("Household")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $shownInvite) { invite in
            InviteSheet(invite: invite)
        }
        .alert("Join Another Household", isPresented: $isAskingCode) {
            TextField("Code", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Join") { isConfirmingJoin = true }
                .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: {
            Text("Enter the code from the invitation.")
        }
        .confirmationDialog("Leave this household and join the other one?", isPresented: $isConfirmingJoin, titleVisibility: .visible) {
            Button("Join") { join() }
        } message: {
            Text("What its members share appears instead of what this household shares.")
        }
    }

    private func header(_ household: HouseholdInfo) -> some View {
        VStack(spacing: Theme.Spacing.sm) {
            Group {
                if let url = household.imageURL {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color(.secondarySystemFill)
                    }
                } else {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.tint)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.tint.opacity(0.12))
                }
            }
            .frame(width: 88, height: 88)
            .clipShape(Circle())
            .accessibilityHidden(true)
            Text(household.name).font(.title2.bold())
            Text(household.members.count == 1 ? String(localized: "1 member") : String(localized: "\(household.members.count) members"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func load() async {
        guard let household = model.household else { return }
        do {
            let info = try await household.household()
            state = .loaded(info)
            invites = info.isAdmin ? ((try? await household.invites()) ?? []) : []
        } catch {
            state = .failed(error.userMessage)
        }
    }

    private func createInvite() {
        guard let household = model.household else { return }
        isCreatingInvite = true
        model.perform {
            defer { isCreatingInvite = false }
            let invite = try await household.createInvite()
            invites.insert(invite, at: 0)
            shownInvite = invite
        }
    }

    private func withdraw(_ invite: HouseholdInvite) {
        guard let household = model.household else { return }
        model.perform {
            try await household.deleteInvite(id: invite.id)
            invites.removeAll { $0.id == invite.id }
        }
    }

    private func join() {
        guard let household = model.household else { return }
        let code = code
        model.perform {
            state = .loaded(try await household.joinHousehold(code: code))
            // Another household's music: the library on the phone starts again.
            await model.syncCatalogues(force: true)
        }
    }
}

private struct MemberRow: View {
    let member: HouseholdMember

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Group {
                if let url = member.imageURL {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        initials
                    }
                } else {
                    initials
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(Circle())
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.isMe ? String(localized: "\(member.name) (you)") : member.name)
                if let role {
                    Text(role).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var role: String? {
        if member.isPending { return String(localized: "Invited") }
        return member.isAdmin ? String(localized: "Admin") : nil
    }

    /// The family's colours, one per person, as in the own.audio logo.
    private static let colours: [Color] = [
        Color(red: 0.98, green: 0.73, blue: 0.02), Color(red: 0.16, green: 0.67, blue: 0.89),
        Color(red: 1.0, green: 0.23, blue: 0.19), Color(red: 1.0, green: 0.8, blue: 0.0),
        Color(red: 0.2, green: 0.78, blue: 0.35),
    ]

    private var initials: some View {
        let letters = member.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        // From the id, so a member keeps their colour (`hashValue` changes every launch).
        let colour = Self.colours[member.id.unicodeScalars.reduce(0) { $0 + Int($1.value) } % Self.colours.count]
        return Text(letters.uppercased())
            .font(.subheadline.bold())
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(colour)
    }
}

/// An invitation to hand on: its code, a QR code of its link, and the share sheet.
private struct InviteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let invite: HouseholdInvite

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Spacing.lg) {
                if let qr {
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                        .padding()
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityLabel("QR code of the invitation")
                }
                Text(invite.code)
                    .font(.title.monospaced().bold())
                    .textSelection(.enabled)
                    .accessibilityIdentifier("household.inviteCode")
                Text("Scanned or typed in, it lets one person join your household.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                ShareLink(item: invite.joinURL?.absoluteString ?? invite.code) {
                    Label("Share Invitation", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
            .padding(Theme.Spacing.lg)
            .navigationTitle("Invitation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var qr: UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data((invite.joinURL?.absoluteString ?? invite.code).utf8)
        guard let image = filter.outputImage,
              let cg = CIContext().createCGImage(image, from: image.extent)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}

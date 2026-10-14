import Foundation
import OwnAudioKit

/// A household on the server: the people in it, and what each shares with the others. Only
/// own.audio servers have one; screens ask `model.activeSource as? HouseholdSource`.
public struct HouseholdInfo: Sendable, Equatable {
    public let name: String
    public let imageURL: URL?
    /// Admins invite people.
    public let isAdmin: Bool
    public let members: [HouseholdMember]
}

public struct HouseholdMember: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let isAdmin: Bool
    /// Invited, not signed in yet.
    public let isPending: Bool
    public let isMe: Bool
    public let imageURL: URL?
}

/// A code that lets someone join; `joinURL` opens the server's own join page with it.
public struct HouseholdInvite: Sendable, Equatable, Identifiable {
    public let id: String
    public let code: String
    public let joinURL: URL?
    public let usesLeft: Int
    /// When it stops working; nil when the server's date can't be read.
    public let expiresAt: Date?
}

public protocol HouseholdSource: MusicSource {
    func household() async throws -> HouseholdInfo
    func invites() async throws -> [HouseholdInvite]
    func createInvite() async throws -> HouseholdInvite
    func deleteInvite(id: String) async throws
    /// Moves the account into the household the code belongs to.
    func joinHousehold(code: String) async throws -> HouseholdInfo
    /// The listener's own songs: shared with the household, or kept to themselves.
    func setShared(songIds: [String], _ shared: Bool) async throws
    func setShared(playlistId: String, _ shared: Bool) async throws
}

extension OwnAudioSource: HouseholdSource {
    /// Only through the API: the Subsonic API has no household.
    private func household<T>(_ work: () async throws -> T) async throws -> T {
        guard await client.tokens.current != nil else { throw SourceError.unsupported }
        do {
            return try await work()
        } catch let error as OwnAudioError {
            throw Self.sourceError(error)
        }
    }

    public func household() async throws -> HouseholdInfo {
        try await household {
            async let family = client.family()
            let members = try await client.members()
            let f = try await family
            return HouseholdInfo(
                name: f.name, imageURL: f.image.flatMap(URL.init(string:)), isAdmin: f.me.role == "admin",
                members: members.map {
                    HouseholdMember(
                        id: $0.userId, name: $0.name, isAdmin: $0.role == "admin", isPending: $0.pending == true,
                        isMe: $0.userId == f.me.userId, imageURL: $0.image.flatMap(URL.init(string:))
                    )
                }
                // You first, then admins, then by name.
                .sorted { ($0.isMe ? 0 : 1, $0.isAdmin ? 0 : 1, $0.name) < ($1.isMe ? 0 : 1, $1.isAdmin ? 0 : 1, $1.name) }
            )
        }
    }

    public func invites() async throws -> [HouseholdInvite] {
        try await household { try await client.invites().filter { $0.useCount < $0.maxUses }.map(Self.invite) }
    }

    public func createInvite() async throws -> HouseholdInvite {
        try await household { Self.invite(try await client.createInvite()) }
    }

    public func deleteInvite(id: String) async throws {
        try await household { try await client.deleteInvite(id: id) }
    }

    public func joinHousehold(code: String) async throws -> HouseholdInfo {
        try await household { _ = try await client.join(code: code.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return try await household()
    }

    public func setShared(songIds: [String], _ shared: Bool) async throws {
        try await household {
            for id in songIds { try await client.setVisibility(trackId: id, shared ? "family" : "private") }
        }
    }

    public func setShared(playlistId: String, _ shared: Bool) async throws {
        try await household { _ = try await client.setVisibility(playlistId: playlistId, shared ? "family" : "private") }
    }

    static func invite(_ i: Invite) -> HouseholdInvite {
        HouseholdInvite(
            id: i.id, code: i.code, joinURL: i.joinUrl.flatMap(URL.init(string:)), usesLeft: max(i.maxUses - i.useCount, 0),
            expiresAt: ISO8601DateFormatter().date(from: i.expiresAt)
                ?? { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.date(from: i.expiresAt) }()
        )
    }
}

import Foundation
import OwnAudioKit

/// A device signed in to an own.audio account. Copied from the books app's `DeviceSession`.
public struct DeviceSession: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: String
    public let name: String?
    public let signedInAt: Date
    public let lastUsedAt: Date?
    public let isThisDevice: Bool
}

extension OwnAudioSource {
    private func devices<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as OwnAudioError {
            throw Self.sourceError(error)
        }
    }

    /// The devices signed in to this account, this one marked.
    public func sessions() async throws -> [DeviceSession] {
        try await devices {
            try await client.sessions().map {
                DeviceSession(id: $0.id, kind: $0.deviceKind, name: $0.deviceName, signedInAt: $0.signedInAt, lastUsedAt: $0.lastUsedAt, isThisDevice: $0.current)
            }
        }
    }

    public func revokeSession(id: String) async throws {
        try await devices { try await client.revokeSession(id: id) }
    }

    /// Every device out, this one included; the server then needs a fresh sign-in.
    public func signOutEverywhere() async throws {
        try await devices { try await client.revokeAllSessions() }
    }
}

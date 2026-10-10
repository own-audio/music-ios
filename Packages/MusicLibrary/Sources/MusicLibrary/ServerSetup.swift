import Foundation
import JellyfinKit
import SubsonicKit

// The app imports only this module; both protocol clients have their own `Song`, `Album`… and
// would clash. What adding a server needs from them is passed through here.

public typealias ClientInfo = JellyfinKit.ClientInfo
public typealias JellyfinSession = JellyfinKit.Session
public typealias JellyfinServerInfo = JellyfinKit.ServerInfo
public typealias QuickConnectRequest = JellyfinClient.QuickConnect

/// Finding out what a server is and signing in to it, before a `ServerRecord` exists.
public enum ServerSetup {
    /// Addresses to try for what was typed, for Jellyfin: with a scheme just that; without one
    /// https first, then http on 8096, then plain http.
    public static func jellyfinCandidates(_ address: String) -> [URL] {
        JellyfinClient.candidateHosts(address)
    }

    /// Answers when there is a Jellyfin at `host`; throws otherwise.
    public static func jellyfinInfo(host: URL, urlSession: URLSession) async throws -> JellyfinServerInfo {
        try await jellyfin { try await JellyfinClient.serverInfo(host: host, urlSession: urlSession) }
    }

    public static func jellyfinSignIn(
        host: URL, username: String, password: String, clientInfo: ClientInfo, urlSession: URLSession
    ) async throws -> JellyfinSession {
        try await jellyfin {
            try await JellyfinClient.signIn(host: host, username: username, password: password, clientInfo: clientInfo, urlSession: urlSession)
        }
    }

    public static func quickConnectEnabled(host: URL, urlSession: URLSession) async -> Bool {
        await JellyfinClient.isQuickConnectEnabled(host: host, urlSession: urlSession)
    }

    public static func startQuickConnect(host: URL, clientInfo: ClientInfo, urlSession: URLSession) async throws -> QuickConnectRequest {
        try await jellyfin { try await JellyfinClient.startQuickConnect(host: host, clientInfo: clientInfo, urlSession: urlSession) }
    }

    public static func checkQuickConnect(host: URL, secret: String, urlSession: URLSession) async throws -> QuickConnectRequest {
        try await jellyfin { try await JellyfinClient.checkQuickConnect(host: host, secret: secret, urlSession: urlSession) }
    }

    public static func finishQuickConnect(
        host: URL, secret: String, clientInfo: ClientInfo, urlSession: URLSession
    ) async throws -> JellyfinSession {
        try await jellyfin {
            try await JellyfinClient.finishQuickConnect(host: host, secret: secret, clientInfo: clientInfo, urlSession: urlSession)
        }
    }

    /// For Subsonic: "host", "host:port" or a full URL; http when no scheme is given.
    public static func subsonicHost(_ address: String) -> URL? {
        SubsonicClient.normalizeHost(address)
    }

    /// Three states, so a mistyped password isn't reported as an outage.
    public static func subsonicCheck(host: URL, username: String, password: String, urlSession: URLSession) async -> ConnectionStatus {
        switch await SubsonicClient(host: host, username: username, password: password, session: urlSession).checkConnection() {
        case .ok: .ok
        case .rejected: .rejected
        case .unreachable: .unreachable
        }
    }

    private static func jellyfin<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as JellyfinClient.JellyfinError {
            throw JellyfinSource.sourceError(error)
        }
    }
}

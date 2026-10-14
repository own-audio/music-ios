import Foundation
import JellyfinKit
import OwnAudioKit
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

// MARK: - own.audio's own API

public typealias OwnAudioTokens = OwnAudioKit.Tokens

/// How a sign-in to an own.audio server through its own API ended.
public enum OwnAudioSignInResult: Sendable {
    /// Signed in: the account's email, and the API's tokens.
    case signedIn(username: String, tokens: OwnAudioTokens)
    /// The account has two-factor sign-in: ask for the code and finish with
    /// `ServerSetup.ownAudioFinishTwoFactor`.
    case twoFactor(mfaToken: String)
}

extension ServerSetup {
    /// Whether the own.audio server at `host` speaks its own API (1.0.0-beta.7 and later).
    public static func ownAudioSpeaksV2(host: URL, urlSession: URLSession) async -> Bool {
        (try? await OwnAudioClient.discover(host: host, session: urlSession))?.v2 != nil
    }

    /// Email and password, through the server's own API.
    public static func ownAudioSignIn(
        host: URL, email: String, password: String, deviceName: String, urlSession: URLSession
    ) async throws -> OwnAudioSignInResult {
        try await finish(host: host, urlSession: urlSession) {
            try await OwnAudioClient.signIn(host: host, email: email, password: password, device: .init(name: deviceName), session: urlSession)
        }
    }

    /// Apple's or Google's id token, through the server's own API.
    public static func ownAudioSignIn(
        host: URL, provider: String, idToken: String, fullName: String?, deviceName: String, urlSession: URLSession
    ) async throws -> OwnAudioSignInResult {
        try await finish(host: host, urlSession: urlSession) {
            try await OwnAudioClient.signIn(host: host, provider: provider, idToken: idToken, fullName: fullName, device: .init(name: deviceName), session: urlSession)
        }
    }

    /// The second step: the authenticator's code, or a recovery code.
    public static func ownAudioFinishTwoFactor(
        host: URL, mfaToken: String, code: String, urlSession: URLSession
    ) async throws -> OwnAudioSignInResult {
        try await finish(host: host, urlSession: urlSession) {
            try await OwnAudioClient.finishTwoFactor(host: host, mfaToken: mfaToken, code: code, session: urlSession)
        }
    }

    /// Tokens, and the account they belong to.
    private static func finish(
        host: URL, urlSession: URLSession, _ signIn: () async throws -> OwnAudioTokens
    ) async throws -> OwnAudioSignInResult {
        let tokens: OwnAudioTokens
        do {
            tokens = try await signIn()
        } catch OwnAudioError.twoFactorRequired(let mfaToken, _) {
            return .twoFactor(mfaToken: mfaToken)
        } catch OwnAudioError.problem(let p) where p.code == "invalid_grant" {
            throw SourceError.signInRejected
        } catch let error as OwnAudioError {
            throw OwnAudioSource.sourceError(error)
        }
        do {
            let me = try await OwnAudioClient(host: host, tokens: TokenSession(tokens), session: urlSession).me()
            return .signedIn(username: me.email, tokens: tokens)
        } catch let error as OwnAudioError {
            throw OwnAudioSource.sourceError(error)
        }
    }
}

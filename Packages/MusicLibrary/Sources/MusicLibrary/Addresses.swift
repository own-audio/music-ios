import Foundation
import JellyfinKit
import SubsonicKit

/// Where an address is reachable from. Decides what is worth trying where, and that a
/// password or token may travel over plain http only on a `lan` address.
public enum AddressScope: String, Codable, Sendable, CaseIterable {
    case lan, vpn, `public`

    /// `lan` for private, link-local and `.local` hosts; `vpn` for the carrier-grade NAT range
    /// Tailscale uses and `*.ts.net`; `public` otherwise. The same rule own.audio's server uses.
    public static func infer(_ url: URL) -> AddressScope {
        guard var host = url.host(percentEncoded: false)?.lowercased() else { return .public }
        if host.hasPrefix("[") { host = String(host.dropFirst().dropLast()) }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") {
            return .lan
        }
        if host.hasSuffix(".ts.net") { return .vpn }
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        if parts.count == 4 {
            let (a, b) = (parts[0], parts[1])
            if a == 100 && (64...127).contains(b) { return .vpn }
            if a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
                || (a == 169 && b == 254) || a == 127 {
                return .lan
            }
            return .public
        }
        if host.contains(":") {
            // fc00::/7 unique local, fe80::/10 link-local, ::1 loopback.
            if host == "::1" || host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe8")
                || host.hasPrefix("fe9") || host.hasPrefix("fea") || host.hasPrefix("feb") {
                return .lan
            }
        }
        return .public
    }
}

public struct ServerAddress: Codable, Sendable, Hashable, Identifiable {
    public enum Origin: String, Codable, Sendable {
        /// The one the server was added with.
        case added
        /// Told by the server.
        case server
        /// Typed by the listener.
        case user
    }

    public let url: URL
    public let scope: AddressScope
    public let origin: Origin

    public var id: URL { url }

    public init(url: URL, scope: AddressScope? = nil, origin: Origin) {
        self.url = url
        self.scope = scope ?? AddressScope.infer(url)
        self.origin = origin
    }

    /// Credentials go over plain http only to an address on the home network, or one the
    /// listener typed or added the server with themselves.
    public var isSafeToUse: Bool {
        url.scheme == "https" || scope == .lan || origin != .server
    }
}

/// How the app picks an address.
public enum ConnectionMode: Codable, Sendable, Equatable {
    /// Try them all after each network change and keep the fastest that is the same server.
    case automatic
    /// Always this one.
    case fixed(URL)
}

/// What an address answered when tried.
public struct AddressCheck: Sendable {
    public let url: URL
    /// The server's identity, where its kind has one.
    public let serverId: String?
    /// More addresses the server named while answering.
    public let addresses: [ServerAddress]
    public let seconds: Double
}

extension ServerSetup {
    /// Asks `url` whether the server is there, cheaply and without signing in where the kind
    /// allows: Jellyfin's public info, own.audio's `GET /api/v1/server`; a Subsonic server has
    /// no identity, so a signed ping. Throws when nothing usable answered.
    public static func check(_ record: ServerRecord, at url: URL, urlSession: URLSession) async throws -> AddressCheck {
        let start = Date()
        switch record.kind {
        case .jellyfin:
            let info = try await JellyfinClient.serverInfo(host: url, urlSession: urlSession)
            let local = info.localAddress.flatMap(URL.init(string:)).map { ServerAddress(url: $0, origin: .server) }
            return AddressCheck(url: url, serverId: info.id, addresses: local.map { [$0] } ?? [], seconds: Date().timeIntervalSince(start))
        case .ownAudio:
            let info = try await ownAudioInfo(at: url, urlSession: urlSession)
            return AddressCheck(url: url, serverId: info.id, addresses: info.addresses, seconds: Date().timeIntervalSince(start))
        case .subsonic:
            guard case .subsonic(let username, let password) = record.auth else { throw SourceError.signInRejected }
            let status = await SubsonicClient(host: url, username: username, password: password, session: urlSession).checkConnection()
            guard status == .ok else { throw status == .rejected ? SourceError.signInRejected : SourceError.network }
            return AddressCheck(url: url, serverId: nil, addresses: [], seconds: Date().timeIntervalSince(start))
        }
    }

    /// own.audio's discovery answer, from revision 6 with its id and addresses.
    public struct OwnAudioInfo: Sendable {
        public let id: String?
        public let addresses: [ServerAddress]
    }

    /// Throws when there is no own.audio server at `url`.
    public static func ownAudioInfo(at url: URL, urlSession: URLSession) async throws -> OwnAudioInfo {
        struct Body: Decodable {
            struct Address: Decodable {
                let url: String
                let scope: String?
            }
            let name: String?
            let id: String?
            let addresses: [Address]?
        }
        let (data, response) = try await urlSession.data(from: url.appending(path: "api/v1/server"))
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONDecoder().decode(Body.self, from: data), body.name == "own.audio"
        else { throw SourceError.unreadable }
        let addresses = (body.addresses ?? []).compactMap { address -> ServerAddress? in
            guard let url = URL(string: address.url) else { return nil }
            return ServerAddress(url: url, scope: address.scope.flatMap(AddressScope.init(rawValue:)), origin: .server)
        }
        return OwnAudioInfo(id: body.id, addresses: addresses)
    }

    /// Tries every candidate at once and returns the fastest that answers as the same server
    /// (`expectedId`, where the kind has ids), or nil when none does.
    public static func race(
        _ record: ServerRecord, candidates: [URL], expectedId: String?, urlSession: URLSession
    ) async -> AddressCheck? {
        let same: AddressCheck? = await withTaskGroup(of: AddressCheck?.self) { group in
            for url in candidates {
                group.addTask {
                    guard let check = try? await check(record, at: url, urlSession: urlSession) else { return nil }
                    // Another server at the same address (the same private IP on another
                    // network, say) must never be taken for this one.
                    if let expectedId, check.serverId != expectedId { return nil }
                    return check
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
        if let same { return same }
        return await reidentified(record, candidates: candidates, expectedId: expectedId, urlSession: urlSession)
    }

    /// A server that was reinstalled or restored from scratch answers with a new identity. The
    /// address the listener added is still trusted then if it is a public https name, whose
    /// certificate already says whose server it is; the caller adopts the new identity.
    /// Home and VPN addresses never get this: the same private address on another network is
    /// someone else's server.
    private static func reidentified(
        _ record: ServerRecord, candidates: [URL], expectedId: String?, urlSession: URLSession
    ) async -> AddressCheck? {
        let host = record.host
        guard expectedId != nil, host.scheme == "https", AddressScope.infer(host) == .public,
              candidates.contains(host),
              let check = try? await check(record, at: host, urlSession: urlSession),
              check.serverId != nil
        else { return nil }
        return check
    }
}

extension ServerSetup {
    /// An own.audio server's Subsonic key for an account, fetched with the account's email and
    /// password: own.audio's Subsonic API takes the key, not the password, and nobody should
    /// have to copy it out of the web app. Throws `.signInRejected` for a wrong password.
    public static func ownAudioSubsonicKey(host: URL, email: String, password: String, urlSession: URLSession) async throws -> (username: String, key: String) {
        struct Login: Decodable { let token: String }
        struct Key: Decodable { let username: String; let api_key: String }

        var login = URLRequest(url: host.appending(path: "api/v1/auth/login"))
        login.httpMethod = "POST"
        login.setValue("application/json", forHTTPHeaderField: "Content-Type")
        login.httpBody = try JSONEncoder().encode(["email": email, "password": password])
        let (loginData, loginResponse) = try await data(for: login, urlSession)
        switch (loginResponse as? HTTPURLResponse)?.statusCode {
        case 200: break
        case 400, 401, 403: throw SourceError.signInRejected
        case let code?: throw SourceError.http(code)
        default: throw SourceError.network
        }
        guard let token = try? JSONDecoder().decode(Login.self, from: loginData).token else { throw SourceError.unreadable }

        var keyRequest = URLRequest(url: host.appending(path: "api/v1/users/me/subsonic-key"))
        keyRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (keyData, keyResponse) = try await data(for: keyRequest, urlSession)
        guard (keyResponse as? HTTPURLResponse)?.statusCode == 200,
              let key = try? JSONDecoder().decode(Key.self, from: keyData)
        else { throw SourceError.unreadable }
        // The account's email as the server stores it, which may differ in case from what was typed.
        return (key.username, key.api_key)
    }

    /// The account a public demo server offers to strangers (`demo` in its discovery answer).
    public static func ownAudioDemoAccount(host: URL, urlSession: URLSession) async throws -> (email: String, password: String) {
        struct Body: Decodable {
            struct Demo: Decodable { let email: String; let password: String }
            let demo: Demo?
        }
        let (data, response) = try await data(for: URLRequest(url: host.appending(path: "api/v1/server")), urlSession)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let demo = try? JSONDecoder().decode(Body.self, from: data).demo
        else { throw SourceError.unreadable }
        return (demo.email, demo.password)
    }

    private static func data(for request: URLRequest, _ session: URLSession) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw SourceError.network
        }
    }
}


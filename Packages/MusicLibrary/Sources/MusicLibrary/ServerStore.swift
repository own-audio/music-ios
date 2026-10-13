import Foundation
import JellyfinKit
import OwnAudioKit
import Security
import SubsonicKit
import os

public enum ServerKind: String, Codable, Sendable, CaseIterable {
    case subsonic, jellyfin
    /// An own.audio server: its library through Subsonic, and its own API for what Subsonic
    /// lacks (its identity and addresses today).
    case ownAudio
}

/// How the app signs in to a server; kept in the Keychain only.
public enum ServerAuth: Codable, Sendable, Equatable {
    /// Subsonic's token+salt scheme needs the password for every request, so it is kept.
    case subsonic(username: String, password: String)
    /// Jellyfin hands out a token; the password is never kept.
    case jellyfin(session: Session)
    /// own.audio from 1.0.0-beta.7: its own API's tokens (rotated on every refresh, so they are
    /// saved again each time) and the account's Subsonic key for what that API doesn't offer
    /// yet. `tokens` is nil once the server has refused a refresh: the key still works, and
    /// signing in again brings the rest back.
    case ownAudio(username: String, key: String, tokens: Tokens?)

    public var username: String {
        switch self {
        case .subsonic(let username, _): username
        case .jellyfin(let session): session.userName
        case .ownAudio(let username, _, _): username
        }
    }
}

/// One configured server. `displayName` defaults to the server's name or host and can be
/// renamed later.
public struct ServerRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var displayName: String
    public let kind: ServerKind
    /// The address the server was added with.
    public var host: URL
    public var auth: ServerAuth
    /// The music library to show where a server has several; nil shows all of them.
    public var libraryId: String?
    /// The server's own identity, where its kind has one (Jellyfin, own.audio). An address that
    /// answers with another id is not this server.
    public var serverId: String?
    /// Every other address the server is known by: told by the server, or added by hand.
    public var addresses: [ServerAddress]
    public var connection: ConnectionMode

    public init(
        id: UUID = UUID(), displayName: String, kind: ServerKind, host: URL, auth: ServerAuth,
        libraryId: String? = nil, serverId: String? = nil, addresses: [ServerAddress] = [],
        connection: ConnectionMode = .automatic
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.host = host
        self.auth = auth
        self.libraryId = libraryId
        self.serverId = serverId
        self.addresses = addresses
        self.connection = connection
    }

    /// Saved before addresses existed: those fields start empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        kind = try c.decode(ServerKind.self, forKey: .kind)
        host = try c.decode(URL.self, forKey: .host)
        auth = try c.decode(ServerAuth.self, forKey: .auth)
        libraryId = try c.decodeIfPresent(String.self, forKey: .libraryId)
        serverId = try c.decodeIfPresent(String.self, forKey: .serverId)
        addresses = try c.decodeIfPresent([ServerAddress].self, forKey: .addresses) ?? []
        connection = try c.decodeIfPresent(ConnectionMode.self, forKey: .connection) ?? .automatic
    }

    /// Every address to try, the one it was added with first, each once, the unsafe ones out.
    public var candidateAddresses: [ServerAddress] {
        var seen = Set<URL>()
        return ([ServerAddress(url: host, origin: .added)] + addresses).filter {
            $0.isSafeToUse && seen.insert(Self.normalized($0.url)).inserted
        }
    }

    /// Adds addresses the server named, keeping the ones already known.
    public mutating func learn(_ named: [ServerAddress]) {
        let known = Set(candidateAddresses.map { Self.normalized($0.url) })
        addresses += named.filter { !known.contains(Self.normalized($0.url)) }
    }

    static func normalized(_ url: URL) -> URL {
        var text = url.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text) ?? url
    }
}

/// Every configured server, stored as a single Keychain item so adding or removing one is a
/// single write.
public actor ServerStore {
    private let service: String
    private let account = "servers"
    private let logger = Logger(subsystem: "audio.own.musicplayer", category: "ServerStore")

    public init(service: String = "audio.own.musicplayer.servers") {
        self.service = service
    }

    public func loadAll() -> [ServerRecord] {
        guard let data = loadRawData() else { return [] }
        do {
            return try JSONDecoder().decode([ServerRecord].self, from: data)
        } catch {
            logger.error("Saved servers could not be decoded.")
            return []
        }
    }

    public func add(_ record: ServerRecord) throws {
        try persist(loadAll() + [record])
    }

    public func remove(id: UUID) throws {
        try persist(loadAll().filter { $0.id != id })
    }

    public func rename(id: UUID, to displayName: String) throws {
        var records = loadAll()
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].displayName = displayName
        try persist(records)
    }

    public func update(_ record: ServerRecord) throws {
        var records = loadAll()
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index] = record
        try persist(records)
    }

    /// own.audio's rotated tokens; nil after a refused refresh.
    public func updateTokens(serverId: UUID, _ tokens: Tokens?) {
        var records = loadAll()
        guard let index = records.firstIndex(where: { $0.id == serverId }),
              case .ownAudio(let username, let key, _) = records[index].auth else { return }
        records[index].auth = .ownAudio(username: username, key: key, tokens: tokens)
        do {
            try persist(records)
        } catch {
            logger.error("Rotated tokens could not be saved.")
        }
    }

    public func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func loadRawData() -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                logger.error("Server load failed: OSStatus \(status, privacy: .public)")
            }
            return nil
        }
        return data
    }

    private func persist(_ records: [ServerRecord]) throws {
        let data = try JSONEncoder().encode(records)
        let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery()
            addQuery[kSecValueData as String] = data
            // Playback continues with the screen locked, and requests need the sign-in then.
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw ServerStoreError.keychain(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw ServerStoreError.keychain(updateStatus)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public enum ServerStoreError: Error, Sendable {
    case keychain(OSStatus)
}

/// What every source shares: the session to make requests with, the saved answers, the offline
/// switch, and how a Jellyfin server sees this device.
public struct SourceEnvironment: Sendable {
    public let urlSession: URLSession
    public let cache: ResponseCache?
    public let offline: OfflineSwitch?
    public let clientInfo: ClientInfo
    /// own.audio's token sessions, one per server for as long as the app runs (see `OwnAudioSessions`).
    public let ownAudioSessions: OwnAudioSessions

    public init(
        urlSession: URLSession, cache: ResponseCache?, offline: OfflineSwitch?, clientInfo: ClientInfo,
        ownAudioSessions: OwnAudioSessions = OwnAudioSessions(store: nil)
    ) {
        self.urlSession = urlSession
        self.cache = cache
        self.offline = offline
        self.clientInfo = clientInfo
        self.ownAudioSessions = ownAudioSessions
    }
}

/// One `TokenSession` per own.audio server, kept across the sources the app rebuilds whenever an
/// address changes. A refresh token works once; two sources refreshing the same one would look
/// like theft to the server, which then signs the device out.
public final class OwnAudioSessions: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [UUID: TokenSession] = [:]
    private var listeners: [UUID: ListenerState] = [:]
    private let store: ServerStore?

    public init(store: ServerStore?) {
        self.store = store
    }

    /// The server's session, made from its saved tokens the first time.
    public func session(for serverId: UUID, tokens: Tokens?) -> TokenSession {
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[serverId] { return existing }
        let made = TokenSession(tokens, keeper: store.map { StoredTokens(store: $0, serverId: serverId) })
        sessions[serverId] = made
        return made
    }

    /// The server's favorites and ratings as the change feed brings them (see `ListenerState`).
    public func listener(for serverId: UUID) -> ListenerState {
        lock.lock()
        defer { lock.unlock() }
        if let existing = listeners[serverId] { return existing }
        let made = ListenerState()
        listeners[serverId] = made
        return made
    }

    /// Forgets a server's session, when it is removed or signed in again.
    public func forget(_ serverId: UUID) {
        lock.lock()
        sessions[serverId] = nil
        listeners[serverId] = nil
        lock.unlock()
    }
}

/// Saves rotated tokens into the server's record in the Keychain.
struct StoredTokens: TokenKeeper {
    let store: ServerStore
    let serverId: UUID

    func save(_ tokens: Tokens?) async {
        await store.updateTokens(serverId: serverId, tokens)
    }
}

extension ServerRecord {
    /// The source for this server, reached at `address` (the one it was added with unless
    /// another was chosen). Saved answers are filed under the server, not the address.
    public func makeSource(_ environment: SourceEnvironment, address: URL? = nil) -> any MusicSource {
        let url = address ?? host
        switch auth {
        case .subsonic(let username, let password):
            return SubsonicSource(client: SubsonicClient(
                host: url, username: username, password: password,
                session: environment.urlSession, cache: environment.cache, offline: environment.offline,
                cacheIdentity: id.uuidString
            ))
        case .jellyfin(let session):
            return JellyfinSource(client: JellyfinClient(
                host: url, session: session, libraryId: libraryId, clientInfo: environment.clientInfo,
                urlSession: environment.urlSession, cache: environment.cache, offline: environment.offline,
                cacheIdentity: id.uuidString
            ))
        case .ownAudio(let username, let key, let tokens):
            let subsonic = SubsonicSource(client: SubsonicClient(
                host: url, username: username, password: key,
                session: environment.urlSession, cache: environment.cache, offline: environment.offline,
                cacheIdentity: id.uuidString
            ))
            let session = environment.ownAudioSessions.session(for: id, tokens: tokens)
            return OwnAudioSource(
                subsonic: subsonic, client: OwnAudioClient(host: url, tokens: session, session: environment.urlSession),
                listener: environment.ownAudioSessions.listener(for: id), offline: environment.offline
            )
        }
    }
}

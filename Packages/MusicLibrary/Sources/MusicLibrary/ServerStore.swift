import Foundation
import JellyfinKit
import Security
import SubsonicKit
import os

public enum ServerKind: String, Codable, Sendable, CaseIterable {
    case subsonic, jellyfin
}

/// How the app signs in to a server; kept in the Keychain only.
public enum ServerAuth: Codable, Sendable, Equatable {
    /// Subsonic's token+salt scheme needs the password for every request, so it is kept.
    case subsonic(username: String, password: String)
    /// Jellyfin hands out a token; the password is never kept.
    case jellyfin(session: Session)

    public var username: String {
        switch self {
        case .subsonic(let username, _): username
        case .jellyfin(let session): session.userName
        }
    }
}

/// One configured server. `displayName` defaults to the server's name or host and can be
/// renamed later.
public struct ServerRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var displayName: String
    public let kind: ServerKind
    public var host: URL
    public var auth: ServerAuth
    /// The music library to show where a server has several; nil shows all of them.
    public var libraryId: String?

    public init(id: UUID = UUID(), displayName: String, kind: ServerKind, host: URL, auth: ServerAuth, libraryId: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.host = host
        self.auth = auth
        self.libraryId = libraryId
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

    public init(urlSession: URLSession, cache: ResponseCache?, offline: OfflineSwitch?, clientInfo: ClientInfo) {
        self.urlSession = urlSession
        self.cache = cache
        self.offline = offline
        self.clientInfo = clientInfo
    }
}

extension ServerRecord {
    /// The source for this server.
    public func makeSource(_ environment: SourceEnvironment) -> any MusicSource {
        switch auth {
        case .subsonic(let username, let password):
            SubsonicSource(client: SubsonicClient(
                host: host, username: username, password: password,
                session: environment.urlSession, cache: environment.cache, offline: environment.offline
            ))
        case .jellyfin(let session):
            JellyfinSource(client: JellyfinClient(
                host: host, session: session, libraryId: libraryId, clientInfo: environment.clientInfo,
                urlSession: environment.urlSession, cache: environment.cache, offline: environment.offline
            ))
        }
    }
}

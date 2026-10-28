import Foundation
import OwnAudioKit
import Testing

@testable import MusicLibrary

@Suite("Saved own.audio tokens", .serialized)
struct ServerStoreTokenTests {
    private func tokens(_ refresh: String) -> Tokens {
        Tokens(accessToken: "access-\(refresh)", refreshToken: refresh, expiresAt: Date().addingTimeInterval(3600), scope: "")
    }

    private func withStore(_ body: (ServerStore) async throws -> Void) async throws {
        let store = ServerStore(service: "audio.own.musicplayer.tests.\(UUID().uuidString)")
        defer { Task { await store.clear() } }
        try await body(store)
    }

    @Test("saving a record loaded before a refresh keeps the rotated tokens")
    func staleCopyKeepsRotatedTokens() async throws {
        try await withStore { store in
            let loaded = ServerRecord(displayName: "own.audio", kind: .ownAudio, host: URL(string: "https://music.example.com")!,
                                      auth: .ownAudio(username: "a@example.com", key: nil, tokens: tokens("first")))
            try await store.add(loaded)
            await store.updateTokens(serverId: loaded.id, tokens("second"))

            var renamed = loaded
            renamed.displayName = "Home"
            renamed.addresses = [ServerAddress(url: URL(string: "http://192.168.1.20:8080")!, origin: .server)]
            let saved = try await store.update(renamed)

            guard case .ownAudio(_, _, let kept) = saved.auth else { Issue.record("not own.audio"); return }
            #expect(kept?.refreshToken == "second")
            #expect(await store.loadAll().first?.auth == saved.auth)
            #expect(await store.loadAll().first?.displayName == "Home")
        }
    }

    @Test("signing in again replaces the tokens")
    func signInReplaces() async throws {
        try await withStore { store in
            let loaded = ServerRecord(displayName: "own.audio", kind: .ownAudio, host: URL(string: "https://music.example.com")!,
                                      auth: .ownAudio(username: "a@example.com", key: nil, tokens: nil))
            try await store.add(loaded)
            var fresh = loaded
            fresh.auth = .ownAudio(username: "a@example.com", key: nil, tokens: tokens("new"))
            try await store.update(fresh, signIn: true)
            #expect(await store.loadAll().first?.auth == fresh.auth)
        }
    }
}

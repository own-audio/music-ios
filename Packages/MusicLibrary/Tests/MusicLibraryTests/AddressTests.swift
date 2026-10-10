import Foundation
import JellyfinKit
import Testing

@testable import MusicLibrary

@Suite("Several addresses per server")
struct AddressTests {
    @Test("scope from the host: home network, VPN, public")
    func scopes() {
        let cases: [(String, AddressScope)] = [
            ("http://192.168.1.20:8096", .lan), ("http://10.0.0.5", .lan), ("http://172.20.1.1", .lan),
            ("http://nas.local:4533", .lan), ("http://[fd12::1]:8096", .lan),
            ("http://100.101.102.103:8096", .vpn), ("https://nas.tail1234.ts.net", .vpn),
            ("https://music.example.com", .public), ("http://172.40.1.1", .public),
        ]
        for (url, scope) in cases {
            #expect(AddressScope.infer(URL(string: url)!) == scope, "\(url)")
        }
    }

    private func record(addresses: [ServerAddress] = []) -> ServerRecord {
        ServerRecord(
            displayName: "Home", kind: .jellyfin, host: URL(string: "https://music.example.com")!,
            auth: .jellyfin(session: JellyfinSession(userId: "u", userName: "u", accessToken: "t", serverId: "s")),
            serverId: "server-1", addresses: addresses
        )
    }

    @Test("candidates: the added address first, each once, plain http from the server only on the home network")
    func candidates() {
        let r = record(addresses: [
            ServerAddress(url: URL(string: "http://192.168.1.20:8096")!, origin: .server),
            ServerAddress(url: URL(string: "http://203.0.113.9:8096")!, origin: .server),
            ServerAddress(url: URL(string: "https://music.example.com/")!, origin: .server),
            ServerAddress(url: URL(string: "http://100.70.0.1:8096")!, origin: .user),
        ])
        #expect(r.candidateAddresses.map(\.url.absoluteString) == [
            "https://music.example.com", "http://192.168.1.20:8096", "http://100.70.0.1:8096",
        ])
    }

    @Test("learning addresses keeps what is known and adds what is new")
    func learn() {
        var r = record()
        r.learn([ServerAddress(url: URL(string: "http://192.168.1.20:8096")!, origin: .server),
                 ServerAddress(url: URL(string: "https://music.example.com")!, origin: .server)])
        r.learn([ServerAddress(url: URL(string: "http://192.168.1.20:8096/")!, origin: .server)])
        #expect(r.addresses.map(\.url.absoluteString) == ["http://192.168.1.20:8096"])
    }

    @Test("a record saved before addresses existed loads with none and automatic connection")
    func oldRecord() throws {
        let old = #"{"id":"6F1C2A0E-3B7D-4C55-9A0E-2F8E1D7C4B19","displayName":"Home","kind":"subsonic","host":"http://nas:4533","auth":{"subsonic":{"username":"u","password":"p"}}}"#
        let r = try JSONDecoder().decode(ServerRecord.self, from: Data(old.utf8))
        #expect(r.addresses.isEmpty)
        #expect(r.connection == .automatic)
        #expect(r.serverId == nil)
    }

    @Test("the race takes an address that answers with the same id, never another server")
    func race() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { request in
            let host = request.url?.host() ?? ""
            // The public name is slow; the home address answers fast but is another server.
            if host == "music.example.com" {
                try await Task.sleep(for: .milliseconds(300))
                return .init(statusCode: 200, body: Data(#"{"Id":"server-1","ServerName":"Home","Version":"12"}"#.utf8))
            }
            if host == "192.168.1.20" {
                return .init(statusCode: 200, body: Data(#"{"Id":"someone-else","ServerName":"Other","Version":"12"}"#.utf8))
            }
            throw URLError(.cannotConnectToHost)
        }
        let r = record()
        let won = await ServerSetup.race(
            r, candidates: [URL(string: "https://music.example.com")!, URL(string: "http://192.168.1.20:8096")!, URL(string: "http://10.9.9.9")!],
            expectedId: "server-1", urlSession: mock.urlSession
        )
        #expect(won?.url.absoluteString == "https://music.example.com")
        #expect(won?.serverId == "server-1")
    }

    @Test("a server reinstalled from scratch is still found at the public https name it was added with, never at a home address")
    func reinstalled() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { request in
            switch request.url?.host() ?? "" {
            case "music.example.com", "192.168.1.20":
                return .init(statusCode: 200, body: Data(#"{"Id":"server-2","ServerName":"Home","Version":"12"}"#.utf8))
            default:
                throw URLError(.cannotConnectToHost)
            }
        }
        let r = record()
        let won = await ServerSetup.race(
            r, candidates: [URL(string: "https://music.example.com")!, URL(string: "http://192.168.1.20:8096")!],
            expectedId: "server-1", urlSession: mock.urlSession
        )
        #expect(won?.url.absoluteString == "https://music.example.com")
        #expect(won?.serverId == "server-2")

        var home = record()
        home.host = URL(string: "http://192.168.1.20:8096")!
        let none = await ServerSetup.race(
            home, candidates: [URL(string: "http://192.168.1.20:8096")!], expectedId: "server-1", urlSession: mock.urlSession
        )
        #expect(none == nil)
    }
}

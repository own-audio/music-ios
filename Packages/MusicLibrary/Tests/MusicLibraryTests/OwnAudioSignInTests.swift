import Foundation
import Testing

@testable import MusicLibrary

@Suite("own.audio sign-in")
struct OwnAudioSignInTests {
    private let host = URL(string: "https://music.example.com")!

    private func json(_ text: String, status: Int = 200) -> MockURLProtocol.StubbedResponse {
        .init(statusCode: status, body: Data(text.utf8), headers: ["Content-Type": "application/json"])
    }

    @Test("email and password give the account's Subsonic key, with the username as stored")
    func key() async throws {
        let stub = await MockURLProtocol.makeStubbedSession { request in
            switch request.url?.path {
            case "/api/v1/auth/login": json(#"{"token":"t1","refresh_token":"r","user":{}}"#)
            case "/api/v1/users/me/subsonic-key":
                request.value(forHTTPHeaderField: "Authorization") == "Bearer t1"
                    ? json(#"{"username":"anna@example.com","api_key":"k123"}"#)
                    : json("{}", status: 401)
            default: json("{}", status: 404)
            }
        }
        let result = try await ServerSetup.ownAudioSubsonicKey(host: host, email: "Anna@example.com", password: "pw", urlSession: stub.urlSession)
        #expect(result.username == "anna@example.com")
        #expect(result.key == "k123")
        let login = try #require(await stub.requestLog().first)
        #expect(login.httpMethod == "POST")
    }

    @Test("a wrong password is a rejected sign-in, not a network error")
    func wrongPassword() async {
        let stub = await MockURLProtocol.makeStubbedSession { _ in json(#"{"error":"invalid credentials"}"#, status: 401) }
        await #expect(throws: SourceError.signInRejected) {
            _ = try await ServerSetup.ownAudioSubsonicKey(host: host, email: "a@example.com", password: "nope", urlSession: stub.urlSession)
        }
    }

    @Test("the demo account comes from the server's discovery answer")
    func demo() async throws {
        let stub = await MockURLProtocol.makeStubbedSession { _ in
            json(#"{"api":{"revision":6},"demo":{"email":"guest@demo.own.audio","password":"own-audio-demo"}}"#)
        }
        let account = try await ServerSetup.ownAudioDemoAccount(host: host, urlSession: stub.urlSession)
        #expect(account.email == "guest@demo.own.audio")
        #expect(account.password == "own-audio-demo")
    }

    @Test("a server without a demo account says so")
    func noDemo() async {
        let stub = await MockURLProtocol.makeStubbedSession { _ in json(#"{"api":{"revision":6}}"#) }
        await #expect(throws: SourceError.unreadable) {
            _ = try await ServerSetup.ownAudioDemoAccount(host: host, urlSession: stub.urlSession)
        }
    }
}

@Suite("own.audio Sign in with Apple")
struct OwnAudioAppleSignInTests {
    private let host = URL(string: "https://music.example.com")!

    private func json(_ text: String, status: Int = 200) -> MockURLProtocol.StubbedResponse {
        .init(statusCode: status, body: Data(text.utf8), headers: ["Content-Type": "application/json"])
    }

    @Test("the server says which sign-in providers it offers")
    func providers() async throws {
        let stub = await MockURLProtocol.makeStubbedSession { _ in
            json(#"{"name":"own.audio","id":"s1","features":{"auth":{"apple":true,"google":false,"local":true}}}"#)
        }
        let info = try await ServerSetup.ownAudioInfo(at: host, urlSession: stub.urlSession)
        #expect(info.signInWithApple)
        #expect(!info.signInWithGoogle)
    }

    @Test("Apple's identity token becomes a session, then the account's Subsonic key")
    func appleThenKey() async throws {
        let stub = await MockURLProtocol.makeStubbedSession { request in
            switch request.url?.path {
            case "/api/v1/auth/apple": json(#"{"token":"t9","refresh_token":"r","user":{}}"#)
            case "/api/v1/users/me/subsonic-key":
                request.value(forHTTPHeaderField: "Authorization") == "Bearer t9"
                    ? json(#"{"username":"kornel@example.com","api_key":"k9"}"#) : json("{}", status: 401)
            default: json("{}", status: 404)
            }
        }
        let token = try await ServerSetup.ownAudioAppleSignIn(host: host, identityToken: "apple-jwt", fullName: "Kornel", deviceName: "iPhone", urlSession: stub.urlSession)
        #expect(token == "t9")
        let key = try await ServerSetup.ownAudioSubsonicKey(host: host, token: token, urlSession: stub.urlSession)
        #expect(key.username == "kornel@example.com" && key.key == "k9")
        let first = await stub.requestLog().first
        let sent = try #require(first?.httpBodyStreamData ?? first?.httpBody)
        let body = try JSONDecoder().decode([String: String].self, from: sent)
        #expect(body["identity_token"] == "apple-jwt" && body["full_name"] == "Kornel" && body["device_kind"] == "ios")
    }

    @Test("the server's reason for refusing is shown")
    func refused() async {
        let stub = await MockURLProtocol.makeStubbedSession { _ in json(#"{"error":"registration is not open"}"#, status: 400) }
        await #expect(throws: SourceError.server("registration is not open")) {
            _ = try await ServerSetup.ownAudioAppleSignIn(host: host, identityToken: "x", fullName: nil, deviceName: "iPhone", urlSession: stub.urlSession)
        }
    }
}

private extension URLRequest {
    /// URLProtocol sees a POST body as a stream.
    var httpBodyStreamData: Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

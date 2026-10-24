import AVFoundation
import Foundation
import Testing

@testable import MusicEngine
@testable import PlayerCore

/// The network plumbing around `AudioStreamDecoder`: real fixture bytes served through
/// `MockURLProtocol`, so the actual `URLSession` download path runs without a live server.
///
/// The `onBuffer` closure is `@Sendable`, so a captured `var` can't be mutated from it; a small
/// reference box can.
private final class FrameCounter: @unchecked Sendable {
    var total: AVAudioFramePosition = 0
}

@Suite("StreamingTrackSource")
struct StreamingTrackSourceTests {
    private static let streamURL = URL(string: "https://music.example.com/rest/stream.view?id=1")!

    private func fixtureData(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func makeSource(_ mock: MockURLProtocol.StubbedSession) -> StreamingTrackSource {
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("streaming-tests-\(UUID().uuidString)", isDirectory: true)
        let fileCache = TrackFileCache(
            remoteURL: { _ in Self.streamURL }, session: mock.urlSession, cacheDirectory: cacheDirectory
        )
        return StreamingTrackSource(fileCache: fileCache, session: mock.urlSession)
    }

    private func serving(_ data: Data, contentType: String) async -> MockURLProtocol.StubbedSession {
        await MockURLProtocol.makeStubbedSession { request in
            guard request.url == Self.streamURL else { return .init(statusCode: 404, body: Data()) }
            return .init(statusCode: 200, body: data, headers: ["Content-Type": contentType])
        }
    }

    @Test("the download arrives in the pieces the network sends, whole and in order, not byte by byte")
    func downloadArrivesInPieces() async throws {
        let body = Data((0..<100_000).map { UInt8($0 % 251) })
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            .init(statusCode: 200, body: body, headers: ["Content-Type": "audio/mpeg"], pieces: 10, pieceDelay: 0.02)
        }
        let (chunks, response) = try await ChunkedDownload.start(Self.streamURL, session: mock.urlSession)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        var received = Data()
        var count = 0
        for try await chunk in chunks {
            received.append(chunk)
            count += 1
        }
        #expect(received == body)
        #expect(count >= 2 && count <= 10, "\(count) pieces")
    }

    @Test("a download whose task is cancelled stops, rather than passing for the whole body")
    func downloadCancels() async throws {
        let body = Data(repeating: 7, count: 200_000)
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            .init(statusCode: 200, body: body, headers: ["Content-Type": "audio/mpeg"], pieces: 20, pieceDelay: 0.1)
        }
        let consumer = Task { () -> Int in
            let (chunks, _) = try await ChunkedDownload.start(Self.streamURL, session: mock.urlSession)
            var total = 0
            for try await chunk in chunks { total += chunk.count }
            try Task.checkCancellation()
            return total
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        consumer.cancel()
        let result = await consumer.result
        #expect(throws: CancellationError.self) { try result.get() }
    }

    @Test("streams a real MP3 end to end, producing roughly its known duration")
    func streamsMP3() async throws {
        let source = makeSource(await serving(try fixtureData("test-tone.mp3"), contentType: "audio/mpeg"))

        let counter = FrameCounter()
        try await source.stream(trackId: "track-1") { decoded in
            counter.total += AVAudioFramePosition(decoded.buffer.frameLength)
        }

        let format = try #require(await source.currentFormatInfo())
        let seconds = Double(counter.total) / format.sampleRate
        #expect((2.9...3.3).contains(seconds), "decoded \(seconds)s from a 3.0s source")
    }

    @Test("streams a real FLAC end to end and reports it as lossless")
    func streamsFLAC() async throws {
        let source = makeSource(await serving(try fixtureData("test-tone.flac"), contentType: "audio/flac"))

        let counter = FrameCounter()
        try await source.stream(trackId: "track-2") { decoded in
            counter.total += AVAudioFramePosition(decoded.buffer.frameLength)
        }

        let format = try #require(await source.currentFormatInfo())
        #expect(format.isLossless)
        let seconds = Double(counter.total) / format.sampleRate
        #expect((2.9...3.2).contains(seconds), "decoded \(seconds)s from a 3.0s source")
    }

    /// Taggers put the cover in the FLAC itself, often a hundred kilobytes or more before the
    /// first frame, so the header arrives over several pieces. That must stream like any other.
    @Test("streams a FLAC with a large embedded cover, without falling back")
    func streamsFLACWithEmbeddedCover() async throws {
        let source = makeSource(await serving(try fixtureData("test-tone-cover.flac"), contentType: "audio/flac"))

        let counter = FrameCounter()
        try await source.stream(trackId: "track-cover") { decoded in
            counter.total += AVAudioFramePosition(decoded.buffer.frameLength)
        }

        let format = try #require(await source.currentFormatInfo())
        let seconds = Double(counter.total) / format.sampleRate
        #expect((2.9...3.2).contains(seconds), "decoded \(seconds)s from a 3.0s source")
    }

    /// Core Audio's FLAC decoder rejects a frame of digital silence in FLAC's shortest form
    /// (14 bytes, every subframe CONSTANT) as bad data, and its stream parser cuts real music at
    /// stray sync codes. A track opening with silence never played while it arrived. The frame
    /// here is the first of such a track.
    @Test("streams a FLAC that opens with a frame of digital silence")
    func streamsFLACOpeningWithSilence() async throws {
        let source = makeSource(await serving(try fixtureData("test-tone-silent-start.flac"), contentType: "audio/flac"))

        let counter = FrameCounter()
        try await source.stream(trackId: "track-silent-start") { decoded in
            counter.total += AVAudioFramePosition(decoded.buffer.frameLength)
        }

        let format = try #require(await source.currentFormatInfo())
        let seconds = Double(counter.total) / format.sampleRate
        #expect((2.9...3.3).contains(seconds), "decoded \(seconds)s from 3.0s of tone after a silent frame")
    }

    /// An M4A/ALAC with its `moov` atom after the audio can't be parsed in pieces. That must
    /// turn into a playable local file, not a failure.
    @Test("falls back to a full local download for the trailing-moov M4A")
    func fallsBackForNotOptimizedALAC() async throws {
        let source = makeSource(await serving(try fixtureData("test-tone.m4a"), contentType: "audio/mp4"))

        do {
            try await source.stream(trackId: "track-3") { _ in }
            Issue.record("expected FallbackToLocalPlaybackRequired")
        } catch let fallback as StreamingTrackSource.FallbackToLocalPlaybackRequired {
            let file = try AVAudioFile(forReading: fallback.localURL)
            let seconds = Double(file.length) / file.fileFormat.sampleRate
            #expect((2.9...3.2).contains(seconds))
            #expect(fallback.localURL.pathExtension == "m4a")
        }
    }

    /// Core Audio's FLAC decoder, once it loses sync, can take packet after packet and give
    /// nothing back, without an error. That used to read the whole track and play none of it;
    /// it now hands over to the whole file, as for any other decoding failure.
    @Test("a decoder that takes bytes and gives no audio hands over to the whole file")
    func silentDecoderFallsBack() async throws {
        let flac = try fixtureData("test-tone.flac")
        let unplayable = flac.prefix(4096) + Data(count: StreamingTrackSource.silentDecoderLimit + 64 * 1024)
        let source = makeSource(await serving(unplayable, contentType: "audio/flac"))

        let counter = FrameCounter()
        do {
            try await source.stream(trackId: "track-silent") { decoded in
                counter.total += AVAudioFramePosition(decoded.buffer.frameLength)
            }
            Issue.record("expected FallbackToLocalPlaybackRequired, decoded \(counter.total) frames")
        } catch is StreamingTrackSource.FallbackToLocalPlaybackRequired {
        }
    }

    @Test("a non-2xx response is a network error, not a decode error")
    func nonSuccessStatusIsNetworkError() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in .init(statusCode: 403, body: Data()) }
        await #expect(throws: PlaybackError.self) {
            try await makeSource(mock).stream(trackId: "track-4") { _ in }
        }
    }

    /// Subsonic answers "not found" and similar with HTTP 200 and a JSON body.
    @Test("a Subsonic error body sent with HTTP 200 is caught before decoding")
    func subsonicErrorBodyIsCaught() async throws {
        let body = Data(String(repeating: " ", count: 64).utf8)
        let json = Data(#"{"subsonic-response":{"status":"failed","error":{"code":70,"message":"not found"}}}"#.utf8) + body
        let source = makeSource(await serving(json, contentType: "application/json"))
        await #expect(throws: PlaybackError.self) {
            try await source.stream(trackId: "track-5") { _ in }
        }
    }
}

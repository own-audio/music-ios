import AVFoundation
import Foundation
import Testing

@testable import MusicEngine
@testable import PlayerCore

/// A real `AVAudioEngine` scheduling real decoded buffers from the fixtures, with only the
/// network mocked. Proves the engine reaches a genuinely playing state; whether it *sounds*
/// right (no gap, no artefact) still needs a device and an ear.
@Suite("PlaybackEngine — streaming")
@MainActor
struct PlaybackEngineStreamingTests {
    private func fixtureData(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private nonisolated static func streamURL(_ trackId: String) -> URL {
        URL(string: "https://music.example.com/rest/stream.view?id=\(trackId)")!
    }

    private struct Harness {
        let engine: PlaybackEngine
        let streamRequestLog: MockURLProtocol.StubbedSession
        let settings: PlaybackSettingsStore
        let fileCache: TrackFileCache
        let nowPlaying: NowPlayingController
    }

    /// Requests seen per track id, so a test can slow down only the first one.
    private final class RequestCounts: @unchecked Sendable {
        private var counts: [String: Int] = [:]
        private let lock = NSLock()
        func next(_ id: String) -> Int { lock.withLock { counts[id, default: 0] += 1; return counts[id]! } }
    }

    /// `failingTrackIds` answer 404. For each of `slowFirstRequest`, the first request (the
    /// fetch ahead of time) answers after `slowSeconds`, and later ones (the stream) arrive in
    /// pieces over about three seconds — a real song still streaming when the fetch is done.
    private func makeHarness(
        suffix: String, audioData: Data, failingTrackIds: Set<String> = [],
        slowFirstRequest: Set<String> = [], slowSeconds: Double = 0, trickle: Set<String> = []
    ) async throws -> Harness {
        let counts = RequestCounts()
        let mock = await MockURLProtocol.makeStubbedSession { request in
            let id = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }?
                .first { $0.name == "id" }?.value ?? ""
            if slowFirstRequest.contains(id) {
                if counts.next(id) == 1 {
                    try? await Task.sleep(nanoseconds: UInt64(slowSeconds * 1_000_000_000))
                } else {
                    return .init(statusCode: 200, body: audioData, headers: ["Content-Type": "audio/mpeg"], pieces: 12, pieceDelay: 0.25)
                }
            }
            if trickle.contains(id) {
                // Slower than it plays: three seconds of audio over six.
                return .init(statusCode: 200, body: audioData, headers: ["Content-Type": "audio/mpeg"], pieces: 12, pieceDelay: 0.5)
            }
            if failingTrackIds.contains(id) { return .init(statusCode: 404, body: Data()) }
            return .init(statusCode: 200, body: audioData, headers: ["Content-Type": "audio/mpeg"])
        }
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-tests-\(UUID().uuidString)", isDirectory: true)
        let fileCache = TrackFileCache(
            remoteURL: { Self.streamURL($0) }, session: mock.urlSession, cacheDirectory: cacheDirectory
        )
        let defaults = UserDefaults(suiteName: "test.engine.settings.\(suffix)")!
        defaults.removePersistentDomain(forName: "test.engine.settings.\(suffix)")
        let settings = PlaybackSettingsStore(defaults: defaults)
        let nowPlaying = NowPlayingController()
        let engine = PlaybackEngine(
            fileCache: fileCache,
            nowPlayingController: nowPlaying,
            settingsStore: settings,
            equalizerStore: EqualizerStore(defaults: UserDefaults(suiteName: "test.engine.eq.\(suffix)")!),
            resumeStore: InMemoryResumeStore()
        )
        return Harness(engine: engine, streamRequestLog: mock, settings: settings, fileCache: fileCache, nowPlaying: nowPlaying)
    }

    private func makeTrack(id: String = "track-1", durationSecs: Int = 3) -> Track {
        Track(id: id, title: "Test Tone", artist: "Fixture", album: nil, durationSecs: durationSecs)
    }

    @Test("play() on an uncached track streams it: real AVAudioEngine reaches isPlaying with real decoded audio")
    func playStreamsAndReachesPlayingState() async throws {
        let harness = try await makeHarness(suffix: "mp3", audioData: try fixtureData("test-tone.mp3"))

        await harness.engine.play(tracks: [makeTrack()])
        // The stream has to actually traverse the mocked network + real decode before the first
        // buffer is scheduled — generous relative to the ~1s a real StreamingTrackSourceTests
        // run takes for the same fixture, tight enough that a real hang still fails the test.
        try await waitUntil(timeout: 5) { harness.engine.isPlaying }

        #expect(harness.engine.isPlaying)
        #expect(harness.engine.currentTrack?.id == "track-1")
        #expect(await harness.streamRequestLog.requestLog().count >= 1)

        harness.engine.stop()
    }

    @Test("in a concert, next and previous move between its songs, and the last song ends next")
    func nextAndPreviousFollowChapters() async throws {
        let harness = try await makeHarness(suffix: "chapters", audioData: try fixtureData("test-tone.mp3"))
        let engine = harness.engine
        engine.setChapters([TrackChapter(title: "One", startSecs: 0), TrackChapter(title: "Two", startSecs: 1.5)], forTrackId: "concert")
        await engine.play(tracks: [makeTrack(id: "concert")])
        try await waitUntil(timeout: 5) { engine.isPlaying }
        #expect(engine.currentChapter?.title == "One")
        #expect(engine.canSkipForward, "a song follows, so next is on though no track does")

        engine.next()
        try await waitUntil(timeout: 5) { engine.currentChapterIndex == 1 }
        #expect(engine.currentTrack?.id == "concert", "next stayed in the concert")
        #expect(!engine.canSkipForward, "the last song, and no track after it")

        engine.previous()
        try await waitUntil(timeout: 5) { engine.currentChapterIndex == 0 }
        #expect(engine.currentTrack?.id == "concert")

        await engine.playChapter(at: 1)
        try await waitUntil(timeout: 5) { engine.currentChapter?.title == "Two" }
        engine.stop()
    }

    @Test("currentTime genuinely advances while a streamed track plays — proof real audio is scheduled, not just state flags")
    func currentTimeAdvancesDuringStreamedPlayback() async throws {
        let harness = try await makeHarness(suffix: "flac", audioData: try fixtureData("test-tone.flac"))

        await harness.engine.play(tracks: [makeTrack(id: "track-2")])
        try await waitUntil(timeout: 5) { harness.engine.isPlaying }

        let firstReading = harness.engine.currentTime
        try await Task.sleep(nanoseconds: 900_000_000) // comfortably more than one 250ms tick
        let secondReading = harness.engine.currentTime

        #expect(secondReading > firstReading, "currentTime didn't advance: \(firstReading) -> \(secondReading)")

        harness.engine.stop()
    }

    @Test("the ALAC trailing-moov fallback still reaches a real playing state via the local-file path")
    func alacFallbackStillReachesPlayingState() async throws {
        let harness = try await makeHarness(suffix: "alac", audioData: try fixtureData("test-tone.m4a"))

        await harness.engine.play(tracks: [makeTrack(id: "track-3")])
        // The fallback needs an extra round trip (the failed stream attempt, then a full
        // re-download through `TrackFileCache.localURL`) — more generous timeout than the
        // straightforward streaming cases above.
        try await waitUntil(timeout: 8) { harness.engine.isPlaying }

        #expect(harness.engine.isPlaying)
        #expect(harness.engine.currentTrack?.id == "track-3")

        harness.engine.stop()
    }

    @Test("a track that fails to stream is skipped automatically, landing on the next one in the queue")
    func failedTrackAutoAdvancesToNext() async throws {
        let harness = try await makeHarness(
            suffix: "autoadvance", audioData: try fixtureData("test-tone.mp3"), failingTrackIds: ["track-fail"]
        )
        let engine = harness.engine

        await engine.play(tracks: [makeTrack(id: "track-fail"), makeTrack(id: "track-2")])
        // The failed track has to actually round-trip its 404 before the auto-skip fires, then
        // the second track has to stream for real — generous relative to the single-track cases
        // above, which only pay one of those two costs.
        try await waitUntil(timeout: 8) { engine.isPlaying }

        #expect(engine.isPlaying)
        #expect(engine.currentTrack?.id == "track-2", "a failed track should be skipped automatically, not leave playback stuck on it")
        #expect(engine.errorMessage == nil, "a track that later succeeds should clear the error the earlier failure left behind")

        engine.stop()
    }

    @Test("a failed track with nothing next just reports the error, rather than looping")
    func failedTrackWithNoNextJustReportsError() async throws {
        let harness = try await makeHarness(
            suffix: "nonext", audioData: Data(), failingTrackIds: ["track-only"]
        )
        let engine = harness.engine

        await engine.play(tracks: [makeTrack(id: "track-only")])
        try await waitUntil(timeout: 5) { engine.errorMessage != nil }

        #expect(!engine.isPlaying)
        #expect(engine.errorMessage == "Could not play this track.")
    }

    @Test("offline, tracks not on the device are passed over without a request")
    func offlineSkipsTracksNotOnDevice() async throws {
        let harness = try await makeHarness(suffix: "offline", audioData: Data())
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("offline-\(UUID().uuidString).mp3")
        try fixtureData("test-tone.mp3").write(to: local)
        await harness.fileCache.setLocalFileLookup { $0 == "track-local" ? local : nil }
        let engine = harness.engine
        engine.requiresLocalFiles = true

        await engine.play(tracks: [makeTrack(id: "track-remote"), makeTrack(id: "track-local"), makeTrack(id: "track-remote-2")])
        try await waitUntil(timeout: 5) { engine.isPlaying }

        #expect(engine.currentTrack?.id == "track-local")
        #expect(await harness.streamRequestLog.requestLog().isEmpty)
        engine.stop()
    }

    @Test("offline, a queue with nothing on the device stops and says why")
    func offlineWithNothingLocalStops() async throws {
        let harness = try await makeHarness(suffix: "offline-none", audioData: Data())
        let engine = harness.engine
        engine.requiresLocalFiles = true

        await engine.play(tracks: [makeTrack(id: "a"), makeTrack(id: "b")])

        #expect(!engine.isPlaying)
        #expect(engine.currentTrack == nil)
        #expect(engine.errorMessage == "Offline, and none of the songs left in the queue are downloaded.")
        #expect(await harness.streamRequestLog.requestLog().isEmpty)
    }

    /// Reproduces a real crash: a server-saved position past the end of the decoded file (the
    /// fixture is 3 s) went negative converting to `AVAudioFrameCount` and trapped.
    @Test("a resume position past the end of the file starts the track over instead of crashing")
    func resumePastEndStartsOver() async throws {
        let harness = try await makeHarness(suffix: "pastend", audioData: try fixtureData("test-tone.mp3"))

        await harness.engine.play(tracks: [makeTrack(id: "track-5")], startTrackId: "track-5", startPositionSecs: 10)
        try await waitUntil(timeout: 8) { harness.engine.isPlaying }

        #expect(harness.engine.isPlaying)
        #expect(harness.engine.currentTime < 3)

        harness.engine.stop()
    }

    @Test("stop() during an in-flight stream cancels cleanly — no crash, no stale state")
    func stopDuringStreamingIsClean() async throws {
        let harness = try await makeHarness(suffix: "cancel", audioData: try fixtureData("test-tone.mp3"))

        await harness.engine.play(tracks: [makeTrack(id: "track-4")])
        // Deliberately not waiting for `isPlaying` — this exercises a stop that lands *during*
        // the network/decode race, the case most likely to leave a dangling Task or a stale
        // completion handler if the generation-check plumbing were wrong.
        harness.engine.stop()

        #expect(!harness.engine.isPlaying)
        #expect(harness.engine.currentTrack == nil)
        // If a stale streaming callback slipped past the generation check, this would flip back
        // to `true` sometime after `stop()` returns — give it a moment, then confirm it didn't.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(!harness.engine.isPlaying)
        #expect(harness.engine.currentTrack == nil)
    }

    /// Scrobbling hangs off these events. A track chained gaplessly onto the previous one never
    /// goes through the load path that reports a start, and used to go unreported.
    @Test("every track reports start and completion, including a gaplessly chained one")
    func chainedTrackReportsItsStart() async throws {
        let harness = try await makeHarness(suffix: "events", audioData: try fixtureData("test-tone.mp3"))
        var started: [String] = []
        var completed: [String] = []
        harness.engine.onPlaybackStarted = { track, _ in started.append(track.id) }
        harness.engine.onPlaybackStopped = { track, _, reason in
            if reason == .completed { completed.append(track.id) }
        }

        await harness.engine.play(tracks: [makeTrack(id: "first"), makeTrack(id: "second")])
        // Two 3 s tracks, the second chained onto the first once it has fully arrived.
        try await waitUntil(timeout: 15) { completed.count == 2 }

        #expect(started == ["first", "second"])
        #expect(completed == ["first", "second"])
        #expect(harness.engine.currentTrack == nil)
    }

    @Test("the sleep timer's end of track: the first track plays out, the next waits paused at its start")
    func sleepAtEndOfTrack() async throws {
        let harness = try await makeHarness(suffix: "sleep", audioData: try fixtureData("test-tone.mp3"))
        var completed: [String] = []
        harness.engine.onPlaybackStopped = { track, _, reason in
            if reason == .completed { completed.append(track.id) }
        }

        await harness.engine.play(tracks: [makeTrack(id: "first"), makeTrack(id: "second")])
        harness.engine.sleepTimer.startUntilEndOfItem()
        try await waitUntil(timeout: 15) { completed == ["first"] && !harness.engine.isPlaying }

        #expect(harness.engine.currentTrack?.id == "second", "the next track is the current one")
        #expect(harness.engine.currentTime < 1, "at its start: \(harness.engine.currentTime)")
        #expect(!harness.engine.sleepTimer.isActive, "the timer is spent")
        try await Task.sleep(for: .seconds(4))
        #expect(completed == ["first"], "and stays paused")
    }

    /// Play Next once the old next track is already chained onto the node: the new one plays
    /// next, then the rest, each once.
    @Test("Play Next after the next track is chained: the new one plays next, nothing twice")
    func playNextAfterChain() async throws {
        let harness = try await makeHarness(suffix: "play-next", audioData: try fixtureData("test-tone.mp3"))
        var started: [String] = []
        var completed: [String] = []
        harness.engine.onPlaybackStarted = { track, _ in started.append(track.id) }
        harness.engine.onPlaybackStopped = { track, _, reason in
            if reason == .completed { completed.append(track.id) }
        }

        await harness.engine.play(tracks: [makeTrack(id: "first"), makeTrack(id: "second")])
        try await waitUntil(timeout: 5) { harness.engine.isPlaying }
        // Long enough for "second" to be fetched and chained.
        try await Task.sleep(for: .seconds(1.5))
        harness.engine.playNext([makeTrack(id: "inserted")])
        #expect(harness.engine.upcomingTracks.map(\.id) == ["inserted", "second"])
        try await waitUntil(timeout: 30) { completed.contains("second") }

        #expect(started.filter { $0 != "first" } == ["inserted", "second"], "in the new order: \(started)")
        #expect(completed == ["first", "inserted", "second"], "each once: \(completed)")
        harness.engine.stop()
    }

    /// A skip while the next track is still being fetched to follow the current one: the fetch
    /// belongs to the old schedule and must not chain anything onto the new one.
    @Test("a skip while the next track is still downloading: each track plays once, in order")
    func skipDuringPrefetch() async throws {
        let harness = try await makeHarness(
            suffix: "skip-prefetch", audioData: try fixtureData("test-tone.mp3"),
            slowFirstRequest: ["second"], slowSeconds: 1
        )
        var started: [String] = []
        var completed: [String] = []
        harness.engine.onPlaybackStarted = { track, _ in started.append(track.id) }
        harness.engine.onPlaybackStopped = { track, _, reason in
            if reason == .completed { completed.append(track.id) }
        }

        await harness.engine.play(tracks: [makeTrack(id: "first"), makeTrack(id: "second"), makeTrack(id: "third")])
        try await waitUntil(timeout: 5) { harness.engine.isPlaying }
        // The first has arrived and the second's fetch ahead is under way: skip now. The
        // second then streams for about three seconds, and the fetch is done after one.
        try await Task.sleep(nanoseconds: 300_000_000)
        harness.engine.next()
        try await waitUntil(timeout: 20) { completed.contains("third") }

        #expect(started == ["first", "second", "third"])
        #expect(completed.filter { $0 == "second" }.count == 1, "the skipped-to track plays once, to its end: \(completed)")
        harness.engine.stop()
    }

    /// A seek restarts the song from its file and cancels the stream; the cancelled stream
    /// used to report itself as a failure, "Could not play this track", and the next song
    /// started instead of the one being sought in.
    @Test("a seek while the song still streams stays on that song")
    func seekWhileStreamingStaysOnTheSong() async throws {
        let harness = try await makeHarness(suffix: "seek-streaming", audioData: try fixtureData("test-tone.mp3"), trickle: ["slow"])
        let engine = harness.engine
        var started: [String] = []
        engine.onPlaybackStarted = { track, _ in started.append(track.id) }

        await engine.play(tracks: [makeTrack(id: "slow"), makeTrack(id: "next")])
        try await waitUntil(timeout: 5) { engine.isPlaying }
        await engine.seek(to: 1.5)
        try await Task.sleep(nanoseconds: 500_000_000)

        #expect(engine.currentTrack?.id == "slow", "still on the song sought in, started: \(started)")
        #expect(engine.errorMessage == nil, "no error: \(engine.errorMessage ?? "")")
        engine.stop()
    }

    @Test("next and previous are available only where the queue goes on")
    func skipButtonsFollowTheQueue() async throws {
        let harness = try await makeHarness(suffix: "skip-buttons", audioData: try fixtureData("test-tone.mp3"))
        let engine = harness.engine
        await engine.play(tracks: [makeTrack(id: "first"), makeTrack(id: "last")])
        try await waitUntil(timeout: 5) { engine.isPlaying }
        #expect(engine.hasNextTrack)
        #expect(!engine.canGoBack, "nothing before the first track at its start")

        engine.next()
        try await waitUntil(timeout: 5) { engine.currentTrack?.id == "last" && engine.isPlaying }
        #expect(!engine.hasNextTrack, "nothing after the last track")
        #expect(engine.canGoBack)
        engine.next()
        #expect(engine.currentTrack?.id == "last", "next at the end does nothing")
        engine.stop()
    }

    /// With crossfade on, a track still streaming used to fade out once playback caught up with
    /// what had arrived — "the end of the data so far" taken for the end of the track. A song
    /// skipped to (so streamed, not fetched ahead) on a slow connection played ten seconds or
    /// so and gave way to the next.
    @Test("crossfade waits for a streaming track's real end, not the end of what has arrived")
    func crossfadeWaitsForTheRealEnd() async throws {
        let harness = try await makeHarness(suffix: "crossfade-stream", audioData: try fixtureData("test-tone.mp3"), trickle: ["slow"])
        harness.settings.setCrossfadeEnabled(true)
        harness.settings.setFadeDurationSecs(2)
        var nextStartedAt: Double?
        let begun = Date()
        harness.engine.onPlaybackStarted = { track, _ in
            if track.id == "next", nextStartedAt == nil { nextStartedAt = Date().timeIntervalSince(begun) }
        }

        await harness.engine.play(tracks: [makeTrack(id: "slow"), makeTrack(id: "next")])
        try await waitUntil(timeout: 20) { nextStartedAt != nil }

        // Its last piece arrives after about 5.5 s; only then is its end known and the fade due.
        let at = nextStartedAt ?? 0
        #expect(at >= 4.5, "the next track should start once the slow one has all arrived, not at \(at) s")
        harness.engine.stop()
    }

    /// The second track is chained gaplessly onto the same node, so its gain has to switch at
    /// the boundary rather than when it was scheduled.
    @Test("each track gets its own ReplayGain, including a chained one, and a mode change applies at once")
    func replayGainPerTrack() async throws {
        let harness = try await makeHarness(suffix: "gain", audioData: try fixtureData("test-tone.mp3"))
        let loud = Track(
            id: "loud", title: "Loud", durationSecs: 3,
            replayGain: TrackGain(trackGainDb: -6.5, albumGainDb: -5, trackPeak: 0.9, albumPeak: 0.95)
        )
        let quiet = Track(
            id: "quiet", title: "Quiet", durationSecs: 3,
            replayGain: TrackGain(trackGainDb: 3.2, albumGainDb: -5, trackPeak: 0.8, albumPeak: 0.95)
        )
        await harness.engine.play(tracks: [loud, quiet])
        try await waitUntil(timeout: 5) { harness.engine.isPlaying }
        #expect(harness.engine.appliedGainDb == -6.5)

        try await waitUntil(timeout: 10) { harness.engine.currentTrack?.id == "quiet" }
        #expect(abs(harness.engine.appliedGainDb - (-20 * log10(0.8))) < 0.0001)

        harness.settings.setReplayGainMode(.album)
        #expect(harness.engine.appliedGainDb == -5)
        harness.settings.setReplayGainMode(.off)
        #expect(harness.engine.appliedGainDb == 0)
        harness.engine.stop()
    }

    /// Polls `condition` instead of a single fixed sleep — real network + real decode timing on
    /// a loaded CI machine is not exactly reproducible, and a flat `#expect` immediately after a
    /// single `Task.sleep` is exactly the kind of flaky test that shape produces.
    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                Issue.record("condition not met within \(timeout)s")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// A WAV of `seconds` of silence at 8 kHz mono, 16-bit: long enough to outrun the look-ahead,
    /// small enough to build in a test, and a format Core Audio parses as a stream.
    private nonisolated static func silentWAV(seconds: Int) -> Data {
        let rate: UInt32 = 8000
        let samples = UInt32(seconds) * rate
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var wav = Data("RIFF".utf8)
        wav.append(le32(36 + samples * 2))
        wav.append(Data("WAVEfmt ".utf8))
        wav.append(le32(16)); wav.append(le16(1)); wav.append(le16(1))
        wav.append(le32(rate)); wav.append(le32(rate * 2)); wav.append(le16(2)); wav.append(le16(16))
        wav.append(Data("data".utf8))
        wav.append(le32(samples * 2))
        wav.append(Data(count: Int(samples) * 2))
        return wav
    }

    @Test("a long stream is decoded no further than the look-ahead while playback waits")
    func longStreamStaysWithinLookahead() async throws {
        // Twenty minutes: ten times the look-ahead, far too much to hold decoded.
        let harness = try await makeHarness(suffix: "lookahead", audioData: Self.silentWAV(seconds: 1200))
        await harness.engine.play(tracks: [makeTrack(id: "long", durationSecs: 1200)])
        try await waitUntil(timeout: 10) { harness.engine.isPlaying }
        harness.engine.pause()
        // Give the decoder every chance to run ahead; it must stop at the cap.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let buffered = harness.engine.bufferedTime
        #expect(buffered > 0, "something should be scheduled")
        #expect(buffered <= PlaybackEngine.streamLookaheadSecs + 30, "the schedule should stop near the look-ahead, not take the whole track: \(buffered) s")
        harness.engine.stop()
    }

    /// The download must not wait for the decoder. It used to: with two minutes decoded ahead
    /// the player stopped reading, the connection sat idle, the request timed out after 15 s
    /// and the song ended early — about 30 s into a FLAC on a fast server.
    @Test("a long stream downloads whole while decoding waits at the look-ahead")
    func longStreamDownloadsWhileDecodingWaits() async throws {
        let harness = try await makeHarness(suffix: "download-ahead", audioData: Self.silentWAV(seconds: 1200))
        await harness.engine.play(tracks: [makeTrack(id: "long", durationSecs: 1200)])
        try await waitUntil(timeout: 10) { harness.engine.isPlaying }
        harness.engine.pause()
        var cached: URL?
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, cached == nil {
            cached = await harness.fileCache.existingLocalURL(trackId: "long")
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        #expect(cached != nil, "the whole file should be in the cache while playback waits")
        #expect(harness.engine.bufferedTime <= PlaybackEngine.streamLookaheadSecs + 30, "decoding still stops at the look-ahead")
        harness.engine.stop()
    }

    @Test("a stream slower than it plays holds instead of stuttering, then finishes")
    func slowStreamBuffersThenFinishes() async throws {
        // Three seconds of audio trickled over six: the listener catches up with the network.
        let harness = try await makeHarness(suffix: "trickle", audioData: try fixtureData("test-tone.mp3"), trickle: ["slow"])
        await harness.engine.play(tracks: [makeTrack(id: "slow")])
        try await waitUntil(timeout: 10) { harness.engine.isPlaying }
        var sawBuffering = false
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, harness.engine.currentTrack != nil {
            if harness.engine.isBuffering { sawBuffering = true }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(sawBuffering, "the player should have paused for the network at least once")
        #expect(harness.engine.currentTrack == nil, "the track should still play to its end")
        #expect(harness.engine.errorMessage == nil)
    }

    @Test("in the background the position moves once a second, and a crossfade still starts on time")
    func backgroundTicksSlowerAndFadesOnTime() async throws {
        let harness = try await makeHarness(suffix: "background-fade", audioData: try fixtureData("test-tone.mp3"))
        let engine = harness.engine
        harness.settings.setCrossfadeEnabled(true)
        harness.settings.setFadeDurationSecs(1)
        for id in ["a", "b"] { _ = try await harness.fileCache.localURL(trackId: id) }
        engine.isInBackground = true
        #expect(engine.tickIntervalSecs == 1)

        await engine.play(tracks: [makeTrack(id: "a"), makeTrack(id: "b")])
        try await waitUntil(timeout: 10) { engine.currentTrack?.id == "b" }
        let left = try #require(engine.crossfadeBeganWithSecsLeft)
        // A tick a second would start it anywhere up to a second late, with too little left.
        #expect(left >= 0.75, "the fade began with \(left) s of the first track left, not about 1 s")
        #expect(left <= 1.4, "the fade began early: \(left) s left")

        engine.isInBackground = false
        #expect(engine.tickIntervalSecs == 0.25)
        engine.stop()
    }

    @Test("paused, the audio engine stops after the grace period; within it, it keeps running")
    func engineIdlesAfterGrace() async throws {
        let harness = try await makeHarness(suffix: "idle", audioData: try fixtureData("test-tone.mp3"))
        let engine = harness.engine
        engine.idleGraceSecs = 0.6
        await engine.play(tracks: [makeTrack()])
        try await waitUntil(timeout: 5) { engine.isPlaying && engine.currentTime > 0.3 }
        #expect(engine.isAudioEngineRunning)

        engine.pause()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(engine.isAudioEngineRunning, "a quick resume finds the engine running")
        engine.togglePlayPause()
        #expect(engine.isPlaying)
        engine.pause()
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(engine.isAudioEngineRunning, "the resume started the grace period over")

        try await waitUntil(timeout: 3) { !engine.isAudioEngineRunning }
        #expect(!engine.isPlaying)
        #expect(engine.currentTrack != nil, "idle is not stop: the track stays loaded")
        engine.stop()
    }

    @Test("after a long pause, play goes on from where it paused and plays to the end", arguments: [false, true])
    func resumesAfterIdleAtTheRightPlace(fromFile: Bool) async throws {
        let harness = try await makeHarness(suffix: "idle-resume-\(fromFile)", audioData: try fixtureData("test-tone.mp3"))
        let engine = harness.engine
        engine.idleGraceSecs = 0.2
        if fromFile { _ = try await harness.fileCache.localURL(trackId: "track-1") }
        await engine.play(tracks: [makeTrack()])
        try await waitUntil(timeout: 10) { engine.isPlaying && engine.currentTime > 0.5 }

        engine.pause()
        let pausedAt = engine.currentTime
        try await waitUntil(timeout: 3) { !engine.isAudioEngineRunning }
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(engine.currentTime == pausedAt, "nothing moves while paused")

        // What the lock screen, the headphones and CarPlay call.
        let resumedAt = Date()
        engine.togglePlayPause()
        #expect(engine.isPlaying)
        #expect(engine.isAudioEngineRunning)
        try await Task.sleep(nanoseconds: 500_000_000)
        let afterResume = engine.currentTime
        let played = Date().timeIntervalSince(resumedAt)
        #expect(afterResume > pausedAt, "the position moves again: \(pausedAt) -> \(afterResume)")
        // No further than the time since the resume: it went on from the pause, not from where
        // the engine's clock would have been had it run through it.
        #expect(afterResume <= pausedAt + played + 0.3, "\(pausedAt) -> \(afterResume) after \(played) s")

        try await waitUntil(timeout: 10) { engine.currentTrack == nil }
        #expect(engine.errorMessage == nil)
    }

    @Test("stop stops the audio engine and gives the audio session back")
    func stopStopsEngineAndSession() async throws {
        let harness = try await makeHarness(suffix: "stop-session", audioData: try fixtureData("test-tone.mp3"))
        let engine = harness.engine
        await engine.play(tracks: [makeTrack()])
        try await waitUntil(timeout: 5) { engine.isPlaying }
        #expect(harness.nowPlaying.isSessionActive)

        engine.stop()
        #expect(!engine.isAudioEngineRunning)
        #expect(!harness.nowPlaying.isSessionActive)

        // And a new play takes it again.
        await engine.play(tracks: [makeTrack(id: "track-2")])
        try await waitUntil(timeout: 5) { engine.isPlaying }
        #expect(engine.isAudioEngineRunning)
        #expect(harness.nowPlaying.isSessionActive)
        engine.stop()
    }

    private func waitUntil(timeout: Double, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(condition())
    }
}

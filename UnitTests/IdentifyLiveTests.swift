import Foundation
import Testing

@testable import OwnAudioMusic

/// How the identify screens follow a run: events first, a poll only when they can't help.
@Suite("Identify live updates")
@MainActor
struct IdentifyLiveTests {
    @Test("a burst of events reloads once at once and once more after the interval, not per event")
    func throttle() async throws {
        let throttle = ReloadThrottle(interval: 0.5)
        var runs: [Date] = []
        let begun = Date()
        for _ in 1...6 { await throttle.run { runs.append(Date()) } }
        #expect(runs.count == 1, "the first at once, the rest wait")
        try await Task.sleep(for: .milliseconds(1500))
        #expect(runs.count == 2, "one more for all the others")
        if runs.count == 2 { #expect(runs[1].timeIntervalSince(begun) >= 0.45) }
        throttle.cancel()
    }

    @Test("a cancelled throttle runs nothing more")
    func throttleCancel() async throws {
        let throttle = ReloadThrottle(interval: 0.3)
        var runs = 0
        await throttle.run { runs += 1 }
        await throttle.run { runs += 1 }
        throttle.cancel()
        try await Task.sleep(for: .milliseconds(600))
        #expect(runs == 1)
    }

    @Test("the poll runs only for an active run the stream can't speak for")
    func pollOnlyWhenNeeded() {
        #expect(!IdentifyFollower.shouldPoll(runActive: false, streamOpen: false, silentFor: 999))
        #expect(IdentifyFollower.shouldPoll(runActive: true, streamOpen: false, silentFor: 0))
        #expect(!IdentifyFollower.shouldPoll(runActive: true, streamOpen: true, silentFor: 5))
        #expect(IdentifyFollower.shouldPoll(runActive: true, streamOpen: true, silentFor: 30))
    }

    @Test("reconnecting waits longer after each failure, up to a minute, and starts over after a connection")
    func backoff() {
        var wait = IdentifyEvents.firstRetry
        var pauses: [Duration] = []
        for _ in 1...7 {
            let (pause, next) = IdentifyEvents.retry(after: wait, opened: false)
            pauses.append(pause)
            wait = next
        }
        #expect(pauses == [2, 4, 8, 16, 32, 60, 60].map { Duration.seconds($0) })
        let (pause, next) = IdentifyEvents.retry(after: wait, opened: true)
        #expect(pause == .seconds(2))
        #expect(next == .seconds(4))
    }
}

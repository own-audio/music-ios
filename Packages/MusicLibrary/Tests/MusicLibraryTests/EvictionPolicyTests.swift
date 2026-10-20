import Foundation
import Testing

@testable import MusicLibrary

@Suite("EvictionPolicy")
struct EvictionPolicyTests {
    private let day: TimeInterval = 86_400
    private var now: Date { Date(timeIntervalSince1970: 1_792_000_000) }

    private var candidates: [EvictionPolicy.Candidate] {
        [
            .init(id: "playing", bytes: 400, isFinished: false, lastUsedAt: now),
            .init(id: "old", bytes: 300, isFinished: false, lastUsedAt: now.addingTimeInterval(-30 * day)),
            .init(id: "finished", bytes: 200, isFinished: true, lastUsedAt: now.addingTimeInterval(-1 * day)),
            .init(id: "recent", bytes: 100, isFinished: false, lastUsedAt: now.addingTimeInterval(-2 * day)),
        ]
    }

    @Test("no cap, nothing goes; under the cap, nothing goes")
    func nothing() {
        #expect(EvictionPolicy(capBytes: nil).evictions(from: candidates, protected: nil).isEmpty)
        #expect(EvictionPolicy(capBytes: 1000).evictions(from: candidates, protected: nil).isEmpty)
    }

    @Test("played episodes go first, then the longest unplayed, until it fits; the playing episode never")
    func order() {
        #expect(EvictionPolicy(capBytes: 900).evictions(from: candidates, protected: "playing") == ["finished"])
        #expect(EvictionPolicy(capBytes: 500).evictions(from: candidates, protected: "playing") == ["finished", "old"])
        #expect(EvictionPolicy(capBytes: 50).evictions(from: candidates, protected: "playing") == ["finished", "old", "recent"])
        #expect(EvictionPolicy(capBytes: 50).evictions(from: candidates, protected: nil) == ["finished", "old", "recent", "playing"])
    }

    @Test("songs: the ones not played for longest go first, the playing one stays")
    func songsByLastUse() {
        let now = Date()
        let songs = [
            EvictionPolicy.Candidate(id: "old", bytes: 40, isFinished: false, lastUsedAt: now.addingTimeInterval(-9 * day)),
            EvictionPolicy.Candidate(id: "playing", bytes: 40, isFinished: false, lastUsedAt: now.addingTimeInterval(-20 * day)),
            EvictionPolicy.Candidate(id: "recent", bytes: 40, isFinished: false, lastUsedAt: now),
            EvictionPolicy.Candidate(id: "middle", bytes: 40, isFinished: false, lastUsedAt: now.addingTimeInterval(-3 * day)),
        ]
        #expect(EvictionPolicy(capBytes: 90).evictions(from: songs, protected: "playing") == ["old", "middle"])
        #expect(EvictionPolicy(capBytes: nil).evictions(from: songs, protected: nil).isEmpty)
    }
}

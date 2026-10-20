import Foundation
import Testing

@testable import MusicEngine

private func track(_ id: String) -> Track {
    Track(id: id, title: "Track \(id)", artist: "Artist", album: "Album", durationSecs: 200)
}

private func ids(_ tracks: [Track]) -> [String] { tracks.map(\.id) }

@Suite("PlayQueue editing")
struct PlayQueueEditingTests {
    private func queue(at start: String = "a") -> PlayQueue {
        PlayQueue(tracks: ["a", "b", "c", "d"].map(track), startTrackId: start)
    }

    @Test("Play Next goes right after the current track, in order, and into the list as shown")
    func playNext() {
        var q = queue(at: "b")
        q.insertNext([track("x"), track("y")])
        #expect(q.currentTrack?.id == "b")
        #expect(ids(q.upcoming) == ["x", "y", "c", "d"])
        #expect(ids(q.played) == ["a"])
        #expect(ids(q.tracks) == ["a", "b", "x", "y", "c", "d"])
    }

    @Test("Add to Queue goes at the end")
    func append() {
        var q = queue()
        q.append([track("x")])
        #expect(ids(q.upcoming) == ["b", "c", "d", "x"])
    }

    @Test("a track already waiting moves instead of playing twice; the current one stays")
    func noDuplicates() {
        var q = queue()
        q.insertNext([track("d"), track("a")])
        #expect(q.currentTrack?.id == "a")
        #expect(ids(q.upcoming) == ["d", "b", "c"])
        q.append([track("d")])
        #expect(ids(q.upcoming) == ["b", "c", "d"])
    }

    @Test("a played track added again moves out of the played part")
    func playedTrackMoves() {
        var q = queue(at: "c")
        q.insertNext([track("a")])
        #expect(ids(q.played) == ["b"])
        #expect(q.currentTrack?.id == "c")
        #expect(ids(q.upcoming) == ["a", "d"])
    }

    @Test("moving and removing count from the first upcoming track")
    func moveAndRemove() {
        var q = queue()
        q.moveUpcoming(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(ids(q.upcoming) == ["d", "b", "c"])
        q.moveUpcoming(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(ids(q.upcoming) == ["b", "c", "d"])
        q.removeUpcoming(atOffsets: IndexSet(integer: 1))
        #expect(ids(q.upcoming) == ["b", "d"])
        #expect(q.currentTrack?.id == "a")
        #expect(q.advance()?.id == "b")
        #expect(q.advance()?.id == "d")
    }

    @Test("with shuffle on, edits change the play order and turning it off keeps the additions")
    func shuffled() {
        var q = queue()
        q.setShuffled(true)
        q.insertNext([track("x")])
        #expect(q.nextTrack?.id == "x")
        #expect(q.upcoming.count == 4)
        q.setShuffled(false)
        #expect(q.currentTrack?.id == "a")
        #expect(Set(ids(q.upcoming)) == ["x", "b", "c", "d"])
        #expect(ids(q.tracks).first == "a")
    }
}

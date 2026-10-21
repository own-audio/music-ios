import Testing

@testable import MusicEngine

@Suite("Chapters")
struct ChapterNavigationTests {
    // The first songs of a concert: an intro, then two songs.
    private let concert = [
        TrackChapter(title: "Intro", startSecs: 0),
        TrackChapter(title: "The Emptiness Machine", startSecs: 157),
        TrackChapter(title: "Lying From You", startSecs: 377),
    ]

    @Test func theChapterPlayingIsTheLastOneStarted() {
        #expect(ChapterNavigation.index(in: concert, at: 0) == 0)
        #expect(ChapterNavigation.index(in: concert, at: 156.9) == 0)
        #expect(ChapterNavigation.index(in: concert, at: 157) == 1)
        #expect(ChapterNavigation.index(in: concert, at: 5000) == 2)
        #expect(ChapterNavigation.index(in: [], at: 10) == nil)
        // A seek lands a hair before the mark it aimed at; it still counts as that chapter.
        #expect(ChapterNavigation.index(in: concert, at: 156.97) == 1)
    }

    @Test func nextGoesToTheNextSongThenLeavesTheTrack() {
        #expect(ChapterNavigation.next(in: concert, at: 10) == 157)
        #expect(ChapterNavigation.next(in: concert, at: 200) == 377)
        #expect(ChapterNavigation.next(in: concert, at: 400) == nil)
        #expect(ChapterNavigation.next(in: [], at: 10) == nil)
    }

    @Test func previousRestartsASongOrGoesBackOne() {
        // Well into a song: back to its start.
        #expect(ChapterNavigation.previous(in: concert, at: 200, restartThreshold: 3) == 157)
        // Just after it began: the song before.
        #expect(ChapterNavigation.previous(in: concert, at: 158, restartThreshold: 3) == 0)
        // In the first chapter the track's own rule decides.
        #expect(ChapterNavigation.previous(in: concert, at: 60, restartThreshold: 3) == nil)
        #expect(ChapterNavigation.previous(in: [], at: 60, restartThreshold: 3) == nil)
    }
}

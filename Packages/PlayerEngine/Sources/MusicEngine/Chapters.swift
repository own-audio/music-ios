import Foundation

/// Where a part of a track begins: one song of a concert recorded as a single file.
public struct TrackChapter: Sendable, Hashable, Codable {
    public let title: String
    public let startSecs: Double

    public init(title: String, startSecs: Double) {
        self.title = title
        self.startSecs = startSecs
    }
}

/// What next and previous do inside a track with chapters. Pure, like `PlayQueue`, so it can be
/// tested without audio. Each answer is a position to seek to, or nil when the skip leaves the
/// track and the queue decides.
public enum ChapterNavigation {
    /// The chapter playing at `time`: the last one that has started. Nil before the first.
    public static func index(in chapters: [TrackChapter], at time: Double) -> Int? {
        chapters.lastIndex { $0.startSecs <= time + 0.05 }
    }

    /// The start of the next chapter; nil in the last one, where next goes to the next track.
    public static func next(in chapters: [TrackChapter], at time: Double) -> Double? {
        let following = (index(in: chapters, at: time) ?? -1) + 1
        return following < chapters.count ? chapters[following].startSecs : nil
    }

    /// Like previous for tracks: a few seconds into a chapter it restarts that chapter, earlier
    /// it goes to the one before. In the first chapter it is nil, and the track's own rule applies
    /// (restart the track, or go to the previous one).
    public static func previous(in chapters: [TrackChapter], at time: Double, restartThreshold: Double) -> Double? {
        guard let current = index(in: chapters, at: time), current > 0 else { return nil }
        if time - chapters[current].startSecs > restartThreshold { return chapters[current].startSecs }
        return chapters[current - 1].startSecs
    }
}

import Testing

@testable import OwnAudioMusic

@Suite("Chapter times")
struct ChapterTimeTests {
    @Test func timesAsPeopleWriteThem() {
        #expect(ChapterTime.format(566) == "9:26")
        #expect(ChapterTime.format(3723.9) == "1:02:03")
        #expect(ChapterTime.format(-5) == "0:00")
        #expect(ChapterTime.parse("9:26") == 566)
        #expect(ChapterTime.parse(" 1:02:03 ") == 3723)
        #expect(ChapterTime.parse("75") == 75)
        #expect(ChapterTime.parse("61:00") == 3660)
    }

    @Test func notTimes() {
        for text in ["", "abc", "1:75", "1::2", "1:2:3:4", "-1:00"] {
            #expect(ChapterTime.parse(text) == nil, "\(text)")
        }
    }
}

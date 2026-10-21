import Foundation

/// A chapter's start as people write it: `9:26`, `1:02:03`, or plain seconds.
enum ChapterTime {
    static func format(_ secs: Double) -> String {
        let total = max(0, Int(secs.rounded(.down)))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Nil for anything that isn't a time.
    static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var secs = 0.0
        for (i, part) in parts.enumerated() {
            guard let value = Double(part), value >= 0, i == 0 || value < 60 else { return nil }
            secs = secs * 60 + value
        }
        return secs
    }
}

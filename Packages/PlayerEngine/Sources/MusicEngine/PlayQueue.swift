import Foundation

/// What happens when the current track finishes on its own -- deliberately does not affect
/// manual `next()`/`previous()`, which always move one literal position regardless of this
/// (`PlaybackEngine`'s own doc comment on why: hijacking a deliberate skip would trap a
/// listener in the current track while `.one` is on).
public enum RepeatMode: String, Sendable, Codable {
    case off, all, one
}

/// Pure track-ordering/transition logic for `PlaybackEngine` — deliberately free of any
/// AVFoundation dependency, same split `PlaybackQueue` makes for audiobooks. `tracks` is the
/// canonical (album/playlist) order; `order` is a separate permutation of indices into it, so
/// toggling shuffle off restores the original order exactly rather than re-deriving it.
public struct PlayQueue: Sendable {
    public private(set) var tracks: [Track]
    private var order: [Int]
    public private(set) var position: Int
    public private(set) var isShuffled = false

    public init(tracks: [Track], startTrackId: String? = nil) {
        self.tracks = tracks
        order = Array(tracks.indices)
        if let startTrackId, let trackIndex = tracks.firstIndex(where: { $0.id == startTrackId }) {
            position = order.firstIndex(of: trackIndex) ?? 0
        } else {
            position = 0
        }
    }

    public var currentTrack: Track? {
        order.indices.contains(position) ? tracks[order[position]] : nil
    }

    public var nextTrack: Track? {
        order.indices.contains(position + 1) ? tracks[order[position + 1]] : nil
    }

    public var previousTrack: Track? {
        order.indices.contains(position - 1) ? tracks[order[position - 1]] : nil
    }

    public var isAtLastTrack: Bool {
        position >= order.count - 1
    }

    /// Where the current track sits in play order, and how many there are.
    public var positionDisplay: (current: Int, total: Int) {
        (current: position + 1, total: order.count)
    }

    /// Where the current track sits **in the list as a screen shows it** — which is a different
    /// number from `positionDisplay` the moment shuffle is on, and the only one a listener can
    /// check against the rows in front of them.
    public var listPositionDisplay: (current: Int, total: Int)? {
        guard let current = currentTrack,
              let index = tracks.firstIndex(where: { $0.id == current.id })
        else { return nil }
        return (current: index + 1, total: tracks.count)
    }

    /// The tracks up to but not including the current one, in play order: what has been heard
    /// on the way here, which is what a container-wide progress bar measures against.
    public var played: [Track] {
        guard position > 0 else { return [] }
        return order[..<position].map { tracks[$0] }
    }

    /// Every track after the current position, in play order — the queue sheet's own list.
    /// `order`/`tracks` are file-private, so this is the seam a caller outside this file (the
    /// engine) has to go through rather than reaching into either directly.
    public var upcoming: [Track] {
        guard position + 1 < order.count else { return [] }
        return order[(position + 1)...].map { tracks[$0] }
    }

    /// Advances to the next track, or `nil` once the queue is exhausted — the caller (the
    /// engine) decides what "queue finished" means (stop, in this app; some players loop).
    @discardableResult
    public mutating func advance() -> Track? {
        guard !isAtLastTrack else {
            position = order.count
            return nil
        }
        position += 1
        return currentTrack
    }

    @discardableResult
    public mutating func goToPrevious() -> Track? {
        guard position > 0 else { return currentTrack }
        position -= 1
        return currentTrack
    }

    @discardableResult
    public mutating func jumpTo(trackId: String) -> Track? {
        guard let trackIndex = tracks.firstIndex(where: { $0.id == trackId }),
              let orderPosition = order.firstIndex(of: trackIndex)
        else { return nil }
        position = orderPosition
        return currentTrack
    }

    /// Pure lookahead, no mutation -- what should play after the current track under
    /// `repeatMode`, for every caller that needs to know *before* the current track actually
    /// finishes (gapless prefetch, crossfade's own early start). `.off` is exactly `nextTrack`;
    /// `.one` is always the current track itself; `.all` wraps to the first track once the
    /// literal `nextTrack` runs out.
    public func trackAfterCurrent(repeatMode: RepeatMode) -> Track? {
        switch repeatMode {
        case .one:
            return currentTrack
        case .off:
            return nextTrack
        case .all:
            return nextTrack ?? order.first.map { tracks[$0] }
        }
    }

    /// The repeat-aware counterpart to `advance()` above, used only where a track finishing
    /// *naturally* should hand off to whatever comes next under `repeatMode` -- `.one` leaves
    /// `position` untouched (the "next" track is this same one, played again) and `.all` wraps
    /// `position` back to the start instead of running off the end into `nil`.
    @discardableResult
    public mutating func advance(repeatMode: RepeatMode) -> Track? {
        switch repeatMode {
        case .one:
            return currentTrack
        case .off:
            return advance()
        case .all:
            guard isAtLastTrack else { return advance() }
            position = 0
            return currentTrack
        }
    }

    /// Re-permutes `order` (or restores canonical order), keeping whatever track is currently
    /// playing right where the listener left it — shuffling out from under the current track
    /// would be a jarring, unrequested track change.
    /// Turns shuffle on or off without disturbing what has already been played.
    ///
    /// Shuffling used to reorder the whole list and then hunt for wherever the playing track had
    /// landed. On track 1 of 17 that routinely left a dozen unplayed songs *behind* the cursor —
    /// they would never play, the album claimed to be two thirds done, and its remaining time
    /// fell by an hour at the press of a button. Only what is still to come gets shuffled; the
    /// songs already heard stay behind, in the order they were heard, and the current one stays
    /// current.
    public mutating func setShuffled(_ shuffled: Bool) {
        isShuffled = shuffled
        guard shuffled else {
            let currentTrackId = currentTrack?.id
            order = Array(tracks.indices)
            if let currentTrackId, let trackIndex = tracks.firstIndex(where: { $0.id == currentTrackId }),
               let orderPosition = order.firstIndex(of: trackIndex) {
                position = orderPosition
            }
            return
        }
        let heard = Array(order[..<min(position, order.count)])
        let current = order.indices.contains(position) ? [order[position]] : []
        let remaining = position + 1 < order.count ? Array(order[(position + 1)...]).shuffled() : []
        order = heard + current + remaining
        // `position` is unchanged on purpose: `heard.count == position` still holds.
    }

    /// Shuffles and starts at the top of the new order — "Shuffle" on an album or artist, where
    /// there is no current track to protect.
    ///
    /// `setShuffled(true)` is the wrong call for that: it pins whatever the queue is pointing at,
    /// which on a queue that has just been built is track 1, so every shuffle began with the same
    /// song and only the rest was random.
    public mutating func shuffleFromStart() {
        order = tracks.indices.shuffled()
        isShuffled = true
        position = 0
    }

    // MARK: - Editing what is still to come

    /// Puts `tracks` right after the current one, in their order. A track already in the queue
    /// moves rather than appearing twice (ids find tracks here); the current track stays put.
    public mutating func insertNext(_ incoming: [Track]) {
        insert(incoming, atOrderPosition: { $0.position + 1 }, canonicalAfterCurrent: true)
    }

    /// Puts `tracks` at the end, in their order; a track already waiting moves there.
    public mutating func append(_ incoming: [Track]) {
        insert(incoming, atOrderPosition: { $0.order.count }, canonicalAfterCurrent: false)
    }

    /// Moves rows of `upcoming`, as a list's drag does: `offsets` and `destination` count from
    /// the first upcoming track.
    public mutating func moveUpcoming(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let base = position + 1
        guard base < order.count else { return }
        var upcoming = Array(order[base...])
        let moving = offsets.filter { upcoming.indices.contains($0) }.map { upcoming[$0] }
        let before = offsets.filter { $0 < destination }.count
        for offset in offsets.sorted(by: >) where upcoming.indices.contains(offset) { upcoming.remove(at: offset) }
        upcoming.insert(contentsOf: moving, at: min(max(destination - before, 0), upcoming.count))
        order = Array(order[..<base]) + upcoming
        settleCanonicalOrder()
    }

    /// Removes rows of `upcoming`.
    public mutating func removeUpcoming(atOffsets offsets: IndexSet) {
        let ids = offsets.compactMap { offset in upcoming.indices.contains(offset) ? upcoming[offset].id : nil }
        for id in ids {
            if let index = tracks.firstIndex(where: { $0.id == id }) { removeTrack(at: index) }
        }
    }

    private mutating func insert(_ incoming: [Track], atOrderPosition where: (Self) -> Int, canonicalAfterCurrent: Bool) {
        let currentId = currentTrack?.id
        var seen = Set<String>()
        let incoming = incoming.filter { $0.id != currentId && seen.insert($0.id).inserted }
        guard !incoming.isEmpty else { return }
        for track in incoming {
            if let index = tracks.firstIndex(where: { $0.id == track.id }) { removeTrack(at: index) }
        }
        var orderPosition = min(`where`(self), order.count)
        // Without shuffle the list a screen shows is the play order, so new tracks go into it
        // where they will play.
        var canonical = canonicalAfterCurrent
            ? (currentTrack.flatMap { current in tracks.firstIndex { $0.id == current.id } }.map { $0 + 1 } ?? tracks.count)
            : tracks.count
        if !isShuffled { canonical = orderPosition }
        for track in incoming {
            tracks.insert(track, at: canonical)
            order = order.map { $0 >= canonical ? $0 + 1 : $0 }
            order.insert(canonical, at: orderPosition)
            canonical += 1
            orderPosition += 1
        }
    }

    /// Drops one track from both orders, keeping the current track current.
    private mutating func removeTrack(at index: Int) {
        guard let orderIndex = order.firstIndex(of: index), orderIndex != position || position >= order.count else { return }
        tracks.remove(at: index)
        order.remove(at: orderIndex)
        order = order.map { $0 > index ? $0 - 1 : $0 }
        if orderIndex < position { position -= 1 }
    }

    /// Without shuffle, the canonical order is the play order: a move changes both.
    private mutating func settleCanonicalOrder() {
        guard !isShuffled else { return }
        tracks = order.map { tracks[$0] }
        order = Array(tracks.indices)
    }
}

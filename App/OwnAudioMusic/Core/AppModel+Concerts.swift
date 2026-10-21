import Foundation
import MusicEngine
import MusicLibrary

/// Concerts: a whole concert as one song, with a chapter where each song of the show starts.
/// The player moves between the chapters; this loads them, resumes a concert where it was
/// left (on any device: the server keeps the position) and saves edited ones.
extension AppModel {
    private static func concertsKey(_ serverId: UUID) -> String { "concertsAvailable.\(serverId.uuidString)" }

    /// Asks the active server; offline, what it said last time.
    func refreshConcertsAvailable() async {
        guard let serverId = activeServerId, let source = activeSource else {
            concertsAvailable = false
            return
        }
        let remembered = UserDefaults.standard.bool(forKey: Self.concertsKey(serverId))
        concertsAvailable = remembered
        guard !isOffline else { return }
        let available = await source.supportsConcerts()
        guard activeServerId == serverId else { return }
        concertsAvailable = available
        UserDefaults.standard.set(available, forKey: Self.concertsKey(serverId))
    }

    func concerts() async throws -> [Album] {
        guard let source = activeSource else { throw SourceError.offline }
        return try await source.concerts()
    }

    func rememberConcerts(_ songs: [Song], serverId: UUID) {
        for song in songs where song.isConcert {
            concertTrackIds.insert(TrackID.make(serverId: serverId, itemId: song.id))
        }
    }

    /// Where to start a concert: where it was left, unless that was its last half minute.
    func concertResumePosition(_ song: Song?) async -> Double {
        guard let song, song.isConcert, !isOffline, let source = activeSource,
              let position = try? await source.savedPosition(songId: song.id), position > 0
        else { return 0 }
        if let duration = song.duration, position > Double(duration) - 30 { return 0 }
        return position
    }

    /// A track that started: if it is a concert, its songs, and its position saved while it plays.
    func concertStarted(_ track: Track) {
        guard isConcert(trackId: track.id) else { return }
        concertTrackIds.insert(track.id)
        Task { await loadChapters(trackId: track.id) }
        concertPositionTask?.cancel()
        concertPositionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled else { return }
                guard self.engine.isPlaying, self.engine.currentTrack?.id == track.id else { continue }
                await self.saveConcertPosition(trackId: track.id, at: self.engine.currentTime)
            }
        }
    }

    /// Paused, stopped, skipped or played out: where the listener is goes to the server. A seek
    /// is a jump within the same listening, saved by the next tick.
    func concertStopped(_ track: Track, at position: Double, reason: PlaybackStopReason) {
        guard reason != .seeked, concertTrackIds.contains(track.id) else { return }
        if reason != .stopped {
            concertPositionTask?.cancel()
            concertPositionTask = nil
        }
        Task { await saveConcertPosition(trackId: track.id, at: position) }
    }

    func saveConcertPosition(trackId: String, at position: Double) async {
        guard let (source, songId) = await resolve(trackId) else { return }
        try? await source.savePosition(songId: songId, positionSecs: position)
    }

    func loadChapters(trackId: String, force: Bool = false) async {
        guard force || engine.chaptersByTrack[trackId] == nil, let (source, songId) = await resolve(trackId),
              let chapters = try? await source.chapters(songId: songId)
        else { return }
        engine.setChapters(chapters.map { TrackChapter(title: $0.title, startSecs: $0.startSecs) }, forTrackId: trackId)
    }

    /// Saves edited songs of a concert; the player follows at once.
    func saveChapters(_ chapters: [SongChapter], trackId: String) async throws {
        guard let (source, songId) = await resolve(trackId) else { throw SourceError.notFound }
        let stored = try await source.saveChapters(songId: songId, chapters)
        engine.setChapters(stored.map { TrackChapter(title: $0.title, startSecs: $0.startSecs) }, forTrackId: trackId)
    }

    /// The playing concert's song, for its sharing (only the owner edits its songs).
    func song(forTrackId trackId: String) -> Song? {
        guard let (serverId, songId) = TrackID.parse(trackId) else { return nil }
        return catalogues[serverId]?.songs.first { $0.id == songId }
    }

    private func isConcert(trackId: String) -> Bool {
        concertTrackIds.contains(trackId) || song(forTrackId: trackId)?.isConcert == true
    }
}

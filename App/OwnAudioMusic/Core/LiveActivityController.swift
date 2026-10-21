import ActivityKit
import Foundation
import MusicEngine
import Observation
import OSLog

private let log = Logger(subsystem: "audio.own.musicplayer", category: "liveActivity")

/// Keeps one Live Activity in step with the player: started when music plays, moved on a new
/// song, play or pause at once and every 15 s while playing, ended when the player stops. The
/// picture goes into the App Group as a small JPEG, since the activity's own state may only
/// carry a few kilobytes. Copied from the podcasts app's `LiveActivityController`; a song
/// changes within the one activity.
@MainActor
final class LiveActivityController {
    private weak var model: AppModel?
    private var activity: Activity<TrackActivityAttributes>?
    private var lastSentAt = Date.distantPast
    private var lastState: TrackActivityAttributes.ContentState?
    /// The picture written for the current song, by track id.
    private var cover: (trackId: String, file: String)?
    private var fetchingCoverFor: String?
    private var ticker: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        PlaybackControlIntent.handler = { [weak model] action in
            guard let engine = model?.engine else { return }
            switch action {
            case .toggle: engine.togglePlayPause()
            case .previous: engine.previous()
            case .next: engine.next()
            }
        }
        observe()
    }

    /// Re-registers for the next change of what the activity shows, as `@Observable` wants.
    private func observe() {
        guard let model else { return }
        withObservationTracking {
            _ = model.engine.currentTrack?.id
            _ = model.engine.isPlaying
        } onChange: {
            Task { @MainActor [weak self] in
                self?.sync(force: true)
                self?.observe()
            }
        }
    }

    private func sync(force: Bool) {
        guard let model else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled, let track = model.engine.currentTrack else {
            end()
            return
        }
        let engine = model.engine
        let state = TrackActivityAttributes.ContentState(
            trackId: track.id, title: track.title, artist: track.artist ?? "",
            positionSecs: engine.currentTime, durationSecs: engine.duration > 0 ? engine.duration : Double(track.durationSecs ?? 0),
            isPlaying: engine.isPlaying, at: Date(),
            coverFile: cover?.trackId == track.id ? cover?.file : nil, hasNext: engine.canSkipForward
        )
        if cover?.trackId != track.id { fetchCover(track) }
        tick(while: engine.isPlaying)
        guard let activity else {
            start(state)
            return
        }
        if !force, Date().timeIntervalSince(lastSentAt) < 15 { return }
        if state == lastState { return }
        lastSentAt = Date()
        lastState = state
        // ActivityKit's handle isn't Sendable; its calls are safe from any task.
        nonisolated(unsafe) let handle = activity
        Task { await handle.update(ActivityContent(state: state, staleDate: nil)) }
    }

    /// The position moves on its own while playing; the activity hears of it every 15 s.
    private func tick(while playing: Bool) {
        if !playing {
            ticker?.cancel()
            ticker = nil
            return
        }
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                self?.sync(force: false)
            }
        }
    }

    private func start(_ state: TrackActivityAttributes.ContentState) {
        do {
            activity = try Activity.request(attributes: TrackActivityAttributes(), content: ActivityContent(state: state, staleDate: nil))
            lastSentAt = Date()
            lastState = state
        } catch {
            log.error("could not start: \(String(describing: error), privacy: .public)")
        }
    }

    /// The cover as a small JPEG in the App Group; the next sync carries its name.
    private func fetchCover(_ track: Track) {
        guard fetchingCoverFor != track.id, let artworkId = track.artworkId, let model else { return }
        fetchingCoverFor = track.id
        let covers = model.covers
        Task { [weak self] in
            defer { if self?.fetchingCoverFor == track.id { self?.fetchingCoverFor = nil } }
            guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: TrackActivityAttributes.appGroup),
                  let data = await covers.data(artworkId: artworkId, size: 160) else { return }
            // One file per cover, so an album's songs share it.
            let name = "cover-" + artworkId.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }.map(String.init).joined() + ".jpg"
            do {
                try data.write(to: group.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                log.error("could not write the picture: \(String(describing: error), privacy: .public)")
                return
            }
            guard let self, self.model?.engine.currentTrack?.id == track.id else { return }
            self.cover = (track.id, name)
            self.sync(force: true)
        }
    }

    private func end() {
        ticker?.cancel()
        ticker = nil
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        nonisolated(unsafe) let handle = activity
        Task { await handle.end(nil, dismissalPolicy: .immediate) }
    }
}

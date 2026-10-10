import Foundation
import MusicLibrary

/// The connected servers' sources, reachable from the engine's background resolver as well as
/// from the UI.
actor ClientRegistry {
    private var sources: [UUID: any MusicSource] = [:]
    /// Set on mobile data when the listener chose a smaller stream; nil streams the original.
    private var maxBitrate: Int?

    func set(_ sources: [UUID: any MusicSource]) {
        self.sources = sources
    }

    func setMaxBitrate(_ bitrate: Int?) {
        maxBitrate = bitrate
    }

    func source(for serverId: UUID) -> (any MusicSource)? {
        sources[serverId]
    }

    /// What the player streams for one of our composite track ids.
    func streamURL(trackId: String) throws -> URL {
        guard let (serverId, songId) = TrackID.parse(trackId), let source = sources[serverId] else {
            throw URLError(.badURL)
        }
        return source.streamURL(songId: songId, maxBitrate: maxBitrate)
    }

    /// Downloads are kept, so they are always the original file.
    func downloadURL(trackId: String) throws -> URL {
        guard let (serverId, songId) = TrackID.parse(trackId), let source = sources[serverId] else {
            throw URLError(.badURL)
        }
        return source.downloadURL(songId: songId)
    }
}

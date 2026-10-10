import Foundation
import JellyfinKit

/// The connected servers' clients, reachable from the engine's background resolver as well as
/// from the UI.
actor ClientRegistry {
    private var clients: [UUID: JellyfinClient] = [:]
    /// Set on mobile data when the listener chose a smaller stream; nil streams the original.
    private var maxBitrate: Int?

    func set(_ clients: [UUID: JellyfinClient]) {
        self.clients = clients
    }

    func client(for serverId: UUID) -> JellyfinClient? {
        clients[serverId]
    }

    func setMaxBitrate(_ bitrate: Int?) {
        maxBitrate = bitrate
    }

    /// What the player streams for one of our composite track ids.
    func streamURL(trackId: String) throws -> URL {
        guard let (serverId, songId) = TrackID.parse(trackId), let client = clients[serverId] else {
            throw URLError(.badURL)
        }
        return client.streamURL(songId: songId, maxBitrate: maxBitrate)
    }

    /// Downloads are kept, so they are always the original file.
    func downloadURL(trackId: String) throws -> URL {
        guard let (serverId, songId) = TrackID.parse(trackId), let client = clients[serverId] else {
            throw URLError(.badURL)
        }
        return client.streamURL(songId: songId)
    }
}

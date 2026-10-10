import Foundation
import MusicEngine
import JellyfinKit

/// The engine knows tracks only by an opaque id. Ours carries the server too, so a queue can
/// mix servers and the resolver knows where to fetch each track from.
enum TrackID {
    private static let separator: Character = "|"

    static func make(serverId: UUID, itemId: String) -> String {
        "\(serverId.uuidString)\(separator)\(itemId)"
    }

    static func parse(_ trackId: String) -> (serverId: UUID, itemId: String)? {
        guard let index = trackId.firstIndex(of: separator),
              let serverId = UUID(uuidString: String(trackId[..<index]))
        else { return nil }
        return (serverId, String(trackId[trackId.index(after: index)...]))
    }
}

extension Song {
    func track(serverId: UUID) -> Track {
        Track(
            id: TrackID.make(serverId: serverId, itemId: id), title: title, artist: artist, album: album,
            durationSecs: duration,
            artworkId: coverArt.map { TrackID.make(serverId: serverId, itemId: $0) },
            // Jellyfin measures loudness per track; there is no album value or peak to protect.
            replayGain: normalizationGain.map {
                TrackGain(trackGainDb: $0, albumGainDb: nil, trackPeak: nil, albumPeak: nil)
            }
        )
    }
}

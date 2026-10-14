import Foundation
import OwnAudioKit

/// A server that takes the listener's own pictures: songs' covers (an album's cover is its
/// songs'), artists' pictures, playlists' covers. Screens ask `activeSource as? ArtworkSource`.
public protocol ArtworkSource: MusicSource {
    /// Each of the listener's own songs given the picture (JPEG or PNG); `albumId` when they are
    /// an album's, whose cover is theirs.
    func setCover(songIds: [String], albumId: String?, image: Data, contentType: String) async throws
    func setPicture(artist: Artist, image: Data, contentType: String) async throws
    func setCover(playlistId: String, image: Data, contentType: String) async throws
}

extension OwnAudioSource: ArtworkSource {
    private func artwork(_ work: () async throws -> Void) async throws {
        guard await client.tokens.current != nil else { throw SourceError.unsupported }
        do {
            try await work()
        } catch let error as OwnAudioError {
            throw Self.sourceError(error)
        }
    }

    public func setCover(songIds: [String], albumId: String?, image: Data, contentType: String) async throws {
        try await artwork {
            for id in songIds { try await client.uploadCover(trackId: id, image: image, contentType: contentType) }
        }
        // The links learned before point at the old picture.
        for id in songIds { records.forget(id) }
        if let albumId { records.forget(albumId) }
    }

    public func setPicture(artist: Artist, image: Data, contentType: String) async throws {
        try await artwork { try await client.uploadArtistImage(name: artist.name, image: image, contentType: contentType) }
        records.forget(artist.id)
    }

    public func setCover(playlistId: String, image: Data, contentType: String) async throws {
        try await artwork { try await client.uploadCover(playlistId: playlistId, image: image, contentType: contentType) }
        records.forget(playlistId)
    }
}

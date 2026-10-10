import Foundation
import JellyfinKit
import SubsonicKit
import Testing

@testable import MusicLibrary

@Suite("Mapping to the shared models")
struct MappingTests {
    @Test("Subsonic: a star is a favorite, a song without a cover takes the album's, ReplayGain carries over")
    func subsonicSong() {
        let song = SubsonicSource.song(SubsonicKit.Song(
            id: "s1", title: "One", albumId: "al1", starred: "2026-01-01T00:00:00Z", userRating: 4,
            replayGain: SubsonicKit.ReplayGain(trackGain: -6.5, trackPeak: 0.9)
        ))
        #expect(song.isFavorite)
        #expect(song.rating == 4)
        #expect(song.coverArt == "al1")
        #expect(song.gain == Gain(track: -6.5, trackPeak: 0.9))
        #expect(song.playlistEntryId == nil)
    }

    @Test("Subsonic: an empty ReplayGain is no gain; an album without a cover id uses its own id")
    func subsonicEmptyGainAndAlbumCover() {
        let song = SubsonicSource.song(SubsonicKit.Song(id: "s1", title: "One", replayGain: SubsonicKit.ReplayGain()))
        #expect(song.gain == nil)
        #expect(!song.isFavorite)
        let album = SubsonicSource.album(SubsonicKit.Album(id: "al1", name: "A", artist: nil, artistId: nil, songCount: 3, duration: nil, coverArt: nil, year: nil))
        #expect(album.coverArt == "al1")
    }

    @Test("Jellyfin: measured loudness becomes a track gain; the playlist entry id is kept")
    func jellyfinSong() {
        let song = JellyfinSource.song(JellyfinKit.Song(
            id: "s1", title: "One", isFavorite: true, normalizationGain: -4.2, playlistItemId: "e7"
        ))
        #expect(song.isFavorite)
        #expect(song.gain == Gain(track: -4.2))
        #expect(song.playlistEntryId == "e7")
        #expect(song.rating == nil)
    }

    @Test("errors become the shared ones")
    func errors() {
        #expect(SubsonicSource.sourceError(.wrongCredentials) == .signInRejected)
        #expect(SubsonicSource.sourceError(.server(code: 70, message: "Not found")) == .server("Not found"))
        #expect(JellyfinSource.sourceError(.unauthorized) == .signInRejected)
        #expect(JellyfinSource.sourceError(.offline) == .offline)
    }

    @Test("an artist image URL with a size parameter is asked for at the size drawn")
    func artistImageSize() {
        let artist = Artist(id: "a", name: "A", imageURL: URL(string: "https://music.example.com/img/a?size=300&x=1"))
        #expect(artist.imageURL(size: 120)?.absoluteString == "https://music.example.com/img/a?size=120&x=1")
        let plain = Artist(id: "b", name: "B", imageURL: URL(string: "https://img.example.com/b.jpg"))
        #expect(plain.imageURL(size: 120)?.absoluteString == "https://img.example.com/b.jpg")
    }

    @Test("Jellyfin has no ratings or highest-rated order; Subsonic has both")
    func capabilities() {
        let subsonic = SubsonicSource(client: SubsonicClient(host: URL(string: "http://h")!, username: "u", password: "p"))
        #expect(subsonic.capabilities.contains(.ratings))
        #expect(subsonic.albumSorts.contains(.highestRated))
        let session = Session(userId: "u", userName: "u", accessToken: "t", serverId: "s")
        let jellyfin = JellyfinSource(client: JellyfinClient(
            host: URL(string: "http://h")!, session: session,
            clientInfo: ClientInfo(client: "c", device: "d", deviceId: "i", version: "1")
        ))
        #expect(!jellyfin.capabilities.contains(.ratings))
        #expect(jellyfin.capabilities.contains(.instantMix))
        #expect(!jellyfin.albumSorts.contains(.highestRated))
    }
}

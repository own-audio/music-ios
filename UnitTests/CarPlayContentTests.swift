import CarPlay
import Foundation
import MusicLibrary
import Testing
@testable import OwnAudioMusic

/// What the car's screen shows, checked without a car (see `CarPlayContent`).
@MainActor
@Suite("CarPlay content")
struct CarPlayContentTests {
    private let server = UUID()

    private func collection(_ name: String) -> DownloadManager.Collection {
        DownloadManager.Collection(id: "album:\(name)", kind: .album, serverId: server, itemId: name, name: name, artist: nil, coverArt: nil, trackIds: [])
    }

    @Test("the start screen lists the six entries in order; with no server none")
    func root() {
        #expect(CarPlayContent.rootEntries(hasServer: true) == [.recentlyPlayed, .recentlyAdded, .downloads, .playlists, .artists, .favorites])
        #expect(CarPlayContent.rootEntries(hasServer: true).map(\.title) == ["Recently Played", "Recently Added", "Downloads", "Playlists", "Artists", "Favorites"])
        #expect(CarPlayContent.rootEntries(hasServer: false).isEmpty)
    }

    @Test("Downloads: loose songs first, then albums and playlists by name, within the cap")
    func downloads() {
        let rows = CarPlayContent.downloadRows(collections: [collection("Zebra"), collection("abba"), collection("Moby")], looseSongs: 4)
        #expect(rows == [.looseSongs(count: 4), .collection(collection("abba")), .collection(collection("Moby")), .collection(collection("Zebra"))])
        #expect(CarPlayContent.downloadRows(collections: [collection("A")], looseSongs: 0) == [.collection(collection("A"))], "no loose songs: no such row")
        let many = (0..<150).map { collection(String(format: "%03d", $0)) }
        #expect(CarPlayContent.downloadRows(collections: many, looseSongs: 2, cap: 100).count == 100)
    }

    @Test("Favorites: the songs as one row first, then albums, within the cap")
    func favorites() {
        let albums = (0..<120).map { Album(id: "a\($0)", name: "Album \($0)") }
        let rows = CarPlayContent.favoriteRows(songs: 12, albums: albums, cap: 100)
        #expect(rows.count == 100)
        #expect(rows.first == .songs(count: 12))
        #expect(rows[1] == .album(albums[0]))
        #expect(CarPlayContent.favoriteRows(songs: 0, albums: Array(albums.prefix(2))) == [.album(albums[0]), .album(albums[1])])
    }

    @Test("a list: one section, its rows, at most the cap, and the empty text")
    func listTemplate() {
        let items = (0..<150).map { CPListItem(text: "Row \($0)", detailText: nil) }
        let template = CarPlayContent.listTemplate(title: "Downloads", items: items, emptyText: "Nothing downloaded")
        #expect(template.title == "Downloads")
        #expect(template.sections.count == 1)
        #expect(template.sections[0].items.count == CarPlayContent.maxItems)
        #expect(CarPlayContent.maxItems <= 100)
        #expect(template.emptyViewTitleVariants == ["Nothing downloaded"])
    }
}

import CarPlay
import Foundation
import MusicLibrary

/// What the car's screen shows, kept apart from the scene delegate so the unit tests can check it
/// without a car: the start list, the rows of Downloads and Favorites, and how a list is built.
/// Shaped like the books and podcasts apps'.
enum CarPlayContent {
    /// CarPlay's guidelines ask for short lists, and each car sets its own cap.
    static var maxItems: Int { min(100, CPListTemplate.maximumItemCount) }

    enum RootEntry: CaseIterable, Equatable {
        case recentlyPlayed, recentlyAdded, downloads, playlists, artists, favorites

        var title: String {
            switch self {
            case .recentlyPlayed: String(localized: "Recently Played")
            case .recentlyAdded: String(localized: "Recently Added")
            case .downloads: String(localized: "Downloads")
            case .playlists: String(localized: "Playlists")
            case .artists: String(localized: "Artists")
            case .favorites: String(localized: "Favorites")
            }
        }

        var symbol: String {
            switch self {
            case .recentlyPlayed: "clock"
            case .recentlyAdded: "sparkles"
            case .downloads: "arrow.down.circle"
            case .playlists: "music.note.list"
            case .artists: "music.mic"
            case .favorites: "star"
            }
        }
    }

    /// With no server, no lists: the start screen says to add one on the iPhone.
    static func rootEntries(hasServer: Bool) -> [RootEntry] {
        hasServer ? RootEntry.allCases : []
    }

    enum DownloadRow: Equatable {
        /// Downloaded songs that belong to no downloaded album or playlist, as one row.
        case looseSongs(count: Int)
        case collection(DownloadManager.Collection)
    }

    /// Downloads: the loose songs first, then albums and playlists by name, within the cap.
    static func downloadRows(collections: [DownloadManager.Collection], looseSongs: Int, cap: Int = maxItems) -> [DownloadRow] {
        let loose: [DownloadRow] = looseSongs > 0 ? [.looseSongs(count: looseSongs)] : []
        let sorted = collections.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        return loose + sorted.prefix(cap - loose.count).map { .collection($0) }
    }

    enum FavoriteRow: Equatable {
        case songs(count: Int)
        case album(Album)
    }

    /// Favorites: all favourite songs as one row first, then the favourite albums, within the cap.
    static func favoriteRows(songs: Int, albums: [Album], cap: Int = maxItems) -> [FavoriteRow] {
        let first: [FavoriteRow] = songs > 0 ? [.songs(count: songs)] : []
        return first + albums.prefix(cap - first.count).map { .album($0) }
    }

    /// A list as the car shows it: one section, the rows, and what it says when empty.
    static func listTemplate(title: String, items: [CPListItem], emptyText: String) -> CPListTemplate {
        let template = CPListTemplate(title: title, sections: [CPListSection(items: Array(items.prefix(maxItems)))])
        template.emptyViewTitleVariants = [emptyText]
        return template
    }
}

import Foundation
import MusicLibrary

/// Changes made while offline — a favorite, a rating, songs added to a playlist — kept until the
/// server can be reached, in the order they were made. The screens show them at once; this is
/// only what still has to reach the server.
struct PendingChanges {
    enum Change: Codable, Equatable {
        case favorite(kind: String, isFavorite: Bool)
        /// From before ratings knew their kind; sent the old way.
        case rating(Int)
        case rated(kind: String, rating: Int)
        case addToPlaylist(playlistId: String, songIds: [String])
    }

    struct Entry: Codable, Equatable {
        let serverId: UUID
        let itemId: String
        let change: Change
        let madeAt: Date
    }

    private let defaults: UserDefaults
    private let key: String
    /// A phone offline for weeks shouldn't grow this without bound.
    static let limit = 1000

    init(defaults: UserDefaults = .standard, key: String = "pendingChanges") {
        self.defaults = defaults
        self.key = key
    }

    var all: [Entry] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    /// A favorite or rating replaces an earlier one for the same item: only the last matters.
    /// Playlist additions all count.
    func add(_ entry: Entry) {
        var entries = all
        switch entry.change {
        case .favorite:
            entries.removeAll { $0.serverId == entry.serverId && $0.itemId == entry.itemId && $0.isFavorite }
        case .rating, .rated:
            entries.removeAll { $0.serverId == entry.serverId && $0.itemId == entry.itemId && $0.isRating }
        case .addToPlaylist:
            break
        }
        save(Array((entries + [entry]).suffix(Self.limit)))
    }

    func remove(_ done: [Entry]) {
        save(all.filter { !done.contains($0) })
    }

    private func save(_ entries: [Entry]) {
        defaults.set(try? JSONEncoder().encode(entries), forKey: key)
    }
}

private extension PendingChanges.Entry {
    var isFavorite: Bool { if case .favorite = change { true } else { false } }
    var isRating: Bool {
        switch change {
        case .rating, .rated: true
        default: false
        }
    }
}

extension PendingChanges.Entry {
    /// What a server that takes them in one request is sent; nil for what goes one call at a
    /// time (playlist edits, and ratings kept before they knew their kind).
    var edit: OfflineEdit? {
        let clientId = "\(serverId.uuidString)/\(itemId)/\(madeAt.timeIntervalSince1970)"
        switch change {
        case .favorite(let kind, let isFavorite):
            return OfflineEdit(clientId: clientId, itemId: itemId, change: .favorite(FavoriteKind(storedName: kind), isFavorite), madeAt: madeAt)
        case .rated(let kind, let rating):
            return OfflineEdit(clientId: clientId, itemId: itemId, change: .rating(FavoriteKind(storedName: kind), rating), madeAt: madeAt)
        case .rating, .addToPlaylist:
            return nil
        }
    }
}

extension FavoriteKind {
    var storedName: String {
        switch self {
        case .song: "song"
        case .album: "album"
        case .artist: "artist"
        }
    }

    init(storedName: String) {
        switch storedName {
        case "album": self = .album
        case "artist": self = .artist
        default: self = .song
        }
    }
}

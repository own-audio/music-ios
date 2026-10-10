import Foundation
import Observation
import UIKit
import MusicEngine
import JellyfinKit

/// The app's single source of truth: configured servers, which one is being browsed, and the
/// one shared player. Built once, in the `App`.
@Observable
@MainActor
final class AppModel {
    /// One per process: the phone UI and CarPlay drive the same player.
    static let shared = AppModel()

    private(set) var servers: [ServerRecord] = []
    private(set) var hasLoaded = false
    private(set) var activeServerId: UUID? {
        didSet { UserDefaults.standard.set(activeServerId?.uuidString, forKey: Self.activeServerKey) }
    }

    let engine: PlaybackEngine
    let playbackSettings: PlaybackSettingsStore
    let equalizer: EqualizerStore
    let covers: CoverArtLoader
    let resumeStore: ResumeStore
    let downloads: DownloadManager

    /// Favorite songs, albums and artists, as composite ids (`TrackID`), learned from whatever
    /// the screens have loaded and kept current when the listener changes one.
    private(set) var favoriteIds: Set<String> = []

    /// A failed action (favorite, playlist edit), shown once as an alert by `RootView`.
    var actionError: String?

    /// Runs a user action and reports a failure in the shared alert.
    func perform(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch {
                actionError = error.userMessage
            }
        }
    }

    /// Set by the listener: play and show only downloaded music, even with a network.
    var downloadedOnly: Bool {
        didSet {
            UserDefaults.standard.set(downloadedOnly, forKey: Self.downloadedOnlyKey)
            applyOfflineState()
        }
    }

    let network = NetworkMonitor()

    /// No network, or the listener chose downloaded music only. Screens then show what is on the
    /// phone and what was seen before, and the player passes over songs that aren't downloaded.
    var isOffline: Bool {
        downloadedOnly || !network.isConnected || Self.isSimulatingOffline
    }

    /// The listener chose it, rather than the network being gone.
    var isOfflineByChoice: Bool { downloadedOnly && network.isConnected && !Self.isSimulatingOffline }

    private func applyOfflineState() {
        offlineSwitch.isOn = isOffline
        engine.requiresLocalFiles = isOffline
    }

    /// Bits per second to stream at on mobile data; nil streams the original file. Downloads are
    /// always the original.
    var mobileBitrate: Int? {
        didSet {
            UserDefaults.standard.set(mobileBitrate ?? 0, forKey: Self.mobileBitrateKey)
            applyStreamQuality()
        }
    }

    static let mobileBitrateChoices: [Int?] = [nil, 320_000, 192_000, 128_000]

    private func applyStreamQuality() {
        let bitrate = network.isExpensive || Self.isSimulatingMobileData ? mobileBitrate : nil
        let registry = registry
        Task { await registry.setMaxBitrate(bitrate) }
    }

    /// Report playback to the server: what is playing (shown on its dashboard), and plays.
    var scrobblingEnabled: Bool {
        didSet { UserDefaults.standard.set(scrobblingEnabled, forKey: Self.scrobblingKey) }
    }

    private let store: ServerStore
    private let registry: ClientRegistry
    private let fileCache: TrackFileCache
    private var clients: [UUID: JellyfinClient] = [:]

    private static let activeServerKey = "activeServerId"
    private static let scrobblingKey = "scrobblingEnabled"
    private static let downloadedOnlyKey = "downloadedOnly"
    private static let deviceIdKey = "deviceId"
    private static let mobileBitrateKey = "mobileBitrate"

    /// How this app shows up in the server's list of devices. The id is made once and kept, so
    /// a reinstall is one device, not a new one each launch.
    static let clientInfo: ClientInfo = {
        let defaults = UserDefaults.standard
        let deviceId = defaults.string(forKey: deviceIdKey) ?? {
            let id = UUID().uuidString
            defaults.set(id, forKey: deviceIdKey)
            return id
        }()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return ClientInfo(client: "own.jelly", device: UIDevice.current.model, deviceId: deviceId, version: version)
    }()

    /// UI tests check offline behaviour by starting the app as if there were no network.
    private static var isSimulatingOffline: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-simulateOffline")
        #else
        false
        #endif
    }
    /// UI tests check the smaller stream by starting the app as if on mobile data.
    private static var isSimulatingMobileData: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-simulateMobileData")
        #else
        false
        #endif
    }
    private var scrobbler: ScrobbleTracker?
    private var scrobbleTickTask: Task<Void, Never>?
    private let pendingScrobbles = PendingScrobbles()
    private let responseCache = DiskResponseCache()
    private let offlineSwitch = OfflineSwitch()
    /// Short timeouts: on a network that is there but goes nowhere, the default minute per
    /// request looks like a frozen app.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    init(store: ServerStore = ServerStore()) {
        self.store = store
        let registry = ClientRegistry()
        self.registry = registry
        covers = CoverArtLoader(registry: registry, offline: offlineSwitch)
        downloads = DownloadManager(registry: registry)
        fileCache = TrackFileCache(remoteURL: { try await registry.streamURL(trackId: $0) }, session: Self.session)
        playbackSettings = PlaybackSettingsStore()
        equalizer = EqualizerStore()
        resumeStore = UserDefaultsResumeStore()
        engine = PlaybackEngine(
            fileCache: fileCache,
            nowPlayingController: NowPlayingController(),
            settingsStore: playbackSettings,
            equalizerStore: equalizer,
            resumeStore: resumeStore
        )
        let covers = covers
        engine.artworkProvider = { track in
            guard let artworkId = track.artworkId else { return nil }
            return await covers.data(artworkId: artworkId, size: 600)
        }
        scrobblingEnabled = UserDefaults.standard.object(forKey: Self.scrobblingKey) as? Bool ?? true
        downloadedOnly = UserDefaults.standard.bool(forKey: Self.downloadedOnlyKey)
        let savedBitrate = UserDefaults.standard.integer(forKey: Self.mobileBitrateKey)
        mobileBitrate = savedBitrate > 0 ? savedBitrate : nil
        applyOfflineState()
        applyStreamQuality()
        network.onChange = { [weak self] connected in
            guard let self else { return }
            self.applyOfflineState()
            self.applyStreamQuality()
            if connected { Task { await self.flushPendingScrobbles() } }
        }
        wireScrobbling()
        // A downloaded song plays from the phone whether or not the server can be reached.
        let files = downloads.files
        let fileCache = fileCache
        Task { await fileCache.setLocalFileLookup { files.url(for: $0) } }
    }

    var activeServer: ServerRecord? {
        servers.first { $0.id == activeServerId }
    }

    var activeClient: JellyfinClient? {
        activeServerId.flatMap { clients[$0] }
    }

    private var loadTask: Task<Void, Never>?

    /// Loads once, however many callers ask: the phone UI and CarPlay can both start the app.
    func load() async {
        if let loadTask { return await loadTask.value }
        let task = Task { await performLoad() }
        loadTask = task
        await task.value
    }

    private func performLoad() async {
        // UI tests start from a clean slate; the Keychain survives reinstalling the app.
        if ProcessInfo.processInfo.arguments.contains("-uiTestReset") {
            await store.clear()
            UserDefaults.standard.removeObject(forKey: Self.activeServerKey)
            await covers.clear()
            downloads.removeAll()
            responseCache.removeAll()
        }
        servers = await store.loadAll()
        await addServerFromLaunchArguments()
        await rebuildClients()
        let saved = UserDefaults.standard.string(forKey: Self.activeServerKey).flatMap(UUID.init)
        activeServerId = servers.contains { $0.id == saved } ? saved : servers.first?.id
        hasLoaded = true
        downloads.resume()
        await flushPendingScrobbles()
    }

    /// Signs in before saving anything, so a typo is caught here rather than on the first screen
    /// that fails. Only the session token is saved, never the password.
    func addServer(address: String, username: String, password: String, name: String) async throws {
        let (host, info) = try await findServer(address)
        let session: Session
        do {
            session = try await JellyfinClient.signIn(host: host, username: username, password: password, clientInfo: Self.clientInfo)
        } catch JellyfinClient.JellyfinError.unauthorized {
            throw AddServerError.rejected
        } catch JellyfinClient.JellyfinError.network {
            throw AddServerError.unreachable
        }
        try await save(host: host, info: info, session: session, name: name)
    }

    /// The server at `address`, and that it is a Jellyfin at all. Without a scheme, each likely
    /// address is tried in turn.
    func findServer(_ address: String) async throws -> (URL, ServerInfo) {
        let candidates = JellyfinClient.candidateHosts(address)
        guard !candidates.isEmpty else { throw AddServerError.invalidAddress }
        var answeredButNotJellyfin = false
        for host in candidates {
            do {
                return (host, try await JellyfinClient.serverInfo(host: host, urlSession: Self.quickSession))
            } catch JellyfinClient.JellyfinError.network {
                continue
            } catch {
                answeredButNotJellyfin = true
            }
        }
        throw answeredButNotJellyfin ? AddServerError.notJellyfin : AddServerError.unreachable
    }

    /// For trying addresses: a wrong guess shouldn't hold the next one up for long.
    private static let quickSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 6
        return URLSession(configuration: configuration)
    }()

    /// Saves a signed-in server and makes it the one shown.
    func save(host: URL, info: ServerInfo, session: Session, name: String) async throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = ServerRecord(
            displayName: trimmedName.isEmpty ? (info.serverName.isEmpty ? (host.host ?? "") : info.serverName) : trimmedName,
            host: host, session: session
        )
        try await store.add(record)
        servers.append(record)
        await rebuildClients()
        activeServerId = record.id
    }

    func removeServer(id: UUID) async throws {
        // Ends the session on the server too, so the device leaves its dashboard.
        if let client = clients[id] { Task.detached { await client.signOut() } }
        try await store.remove(id: id)
        servers.removeAll { $0.id == id }
        downloads.removeAll(serverId: id)
        // Saved answers are keyed by server; this server's are of no further use, and it is
        // simpler to let the others be fetched again than to pick them apart.
        responseCache.removeAll()
        if let track = engine.currentTrack, TrackID.parse(track.id)?.serverId == id { engine.stop() }
        await rebuildClients()
        if activeServerId == id { activeServerId = servers.first?.id }
    }

    func renameServer(id: UUID, to name: String) async throws {
        try await store.rename(id: id, to: name)
        if let index = servers.firstIndex(where: { $0.id == id }) { servers[index].displayName = name }
    }

    /// Shows one music library of a server, or all of them with nil.
    func setLibrary(serverId: UUID, libraryId: String?) async throws {
        guard var record = servers.first(where: { $0.id == serverId }) else { return }
        record.libraryId = libraryId
        try await store.update(record)
        if let index = servers.firstIndex(where: { $0.id == serverId }) { servers[index] = record }
        responseCache.removeAll()
        await rebuildClients()
    }

    func musicLibraries(serverId: UUID) async -> [MusicLibrary] {
        guard let record = servers.first(where: { $0.id == serverId }) else { return [] }
        let unscoped = JellyfinClient(host: record.host, session: record.session, clientInfo: Self.clientInfo, urlSession: Self.session)
        return (try? await unscoped.musicLibraries()) ?? []
    }

    func selectServer(id: UUID) {
        guard servers.contains(where: { $0.id == id }) else { return }
        activeServerId = id
    }

    func checkConnection(id: UUID) async -> ConnectionStatus {
        guard let client = clients[id] else { return .unreachable }
        return await client.checkSession()
    }

    /// Plays `songs` from the active server, starting at `startSongId` or the first song.
    /// `containerId` ("album:…") lets the engine remember where in it listening stopped.
    /// Offline, only the downloaded ones; a tapped song that isn't downloaded starts the list at
    /// the next one that is.
    func play(_ songs: [Song], startSongId: String? = nil, shuffled: Bool = false, containerId: String? = nil) {
        guard let serverId = activeServerId, !songs.isEmpty else { return }
        var songs = songs
        var startSongId = startSongId
        if isOffline {
            let isLocal = { (song: Song) in self.downloads.isDownloaded(TrackID.make(serverId: serverId, itemId: song.id)) }
            if let start = startSongId, let index = songs.firstIndex(where: { $0.id == start }), !isLocal(songs[index]) {
                startSongId = songs[index...].first(where: isLocal)?.id
            }
            songs = songs.filter(isLocal)
            guard !songs.isEmpty else {
                actionError = String(localized: "You're offline, and none of these songs are downloaded.")
                return
            }
        }
        let tracks = songs.map { $0.track(serverId: serverId) }
        engine.setShuffled(shuffled)
        Task {
            await engine.play(
                tracks: tracks,
                startTrackId: startSongId.map { TrackID.make(serverId: serverId, itemId: $0) },
                containerId: containerId.map { "\(serverId.uuidString)|\($0)" }
            )
        }
    }

    /// Debug builds only: `-debugServerHost <url> -debugServerUser <name> -debugServerPassword <secret>`
    /// signs in to that server at launch if it isn't there yet, so a simulator can be handed to
    /// someone already connected.
    private func addServerFromLaunchArguments() async {
        #if DEBUG
        let defaults = UserDefaults.standard
        guard let address = defaults.string(forKey: "debugServerHost"),
              let username = defaults.string(forKey: "debugServerUser"),
              let password = defaults.string(forKey: "debugServerPassword"),
              let host = JellyfinClient.normalizeHost(address),
              !servers.contains(where: { $0.host == host && $0.session.userName == username }),
              let session = try? await JellyfinClient.signIn(host: host, username: username, password: password, clientInfo: Self.clientInfo)
        else { return }
        let record = ServerRecord(displayName: defaults.string(forKey: "debugServerName") ?? host.host ?? address, host: host, session: session)
        try? await store.add(record)
        servers.append(record)
        UserDefaults.standard.set(record.id.uuidString, forKey: Self.activeServerKey)
        #endif
    }

    // MARK: - Scrobbling

    private func wireScrobbling() {
        let scrobbler = ScrobbleTracker { [weak self] event in self?.report(event) }
        self.scrobbler = scrobbler
        engine.onPlaybackStarted = { [weak self] track, position in
            guard let self, self.scrobblingEnabled else { return }
            scrobbler.started(key: track.id, durationSecs: track.durationSecs)
            self.startScrobbleTicks()
            Task { await self.reportSession(.start, trackId: track.id, position: position) }
        }
        engine.onPlaybackStopped = { [weak self] track, position, reason in
            guard let self, self.scrobblingEnabled else { return }
            let isEnd: Bool = switch reason {
            case .completed, .skipped, .replaced: true
            case .stopped, .seeked: false
            }
            scrobbler.stopped(key: track.id, isEnd: isEnd)
            // A seek is a jump inside the same playback, not its end.
            if reason != .seeked {
                Task { await self.reportSession(.stopped, trackId: track.id, position: position) }
            }
        }
    }

    private enum SessionEvent { case start, progress, stopped }

    /// Tracks whose start the server heard. Jellyfin counts those plays itself from the
    /// reports; only plays it never heard about (offline) are sent afterwards.
    private var reportedLive: Set<String> = []

    private func reportSession(_ event: SessionEvent, trackId: String, position: Double) async {
        guard scrobblingEnabled, let (client, songId) = await resolve(trackId) else { return }
        do {
            switch event {
            case .start:
                try await client.reportStart(songId: songId, positionSecs: position)
                reportedLive.insert(trackId)
            case .progress:
                try await client.reportProgress(songId: songId, positionSecs: position, isPaused: !engine.isPlaying)
            case .stopped:
                try await client.reportStopped(songId: songId, positionSecs: position)
            }
        } catch {}
    }

    /// Counts a play while it is still playing, so it isn't lost if the app is killed.
    private func startScrobbleTicks() {
        guard scrobbleTickTask == nil else { return }
        scrobbleTickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self else { return }
                if self.engine.isPlaying { self.scrobbler?.tick() }
                // Without a report now and then the server takes the session for ended.
                if let track = self.engine.currentTrack {
                    await self.reportSession(.progress, trackId: track.id, position: self.engine.currentTime)
                }
            }
        }
    }

    private func report(_ event: ScrobbleTracker.Event) {
        Task {
            switch event {
            case .nowPlaying:
                // Covered by the session report sent when playback started.
                break
            case .played(let trackId, let startedAt):
                guard !reportedLive.contains(trackId) else { return }
                let entry = PendingScrobbles.Entry(trackId: trackId, startedAt: startedAt)
                if await submit(entry) {
                    await flushPendingScrobbles()
                } else {
                    pendingScrobbles.add(entry)
                }
            }
        }
    }

    private func submit(_ entry: PendingScrobbles.Entry) async -> Bool {
        guard let (client, songId) = await resolve(entry.trackId) else {
            // The server was removed; there's nowhere to report it.
            return true
        }
        do {
            try await client.markPlayed(songId: songId, at: entry.startedAt)
            return true
        } catch {
            return false
        }
    }

    /// Sends plays that couldn't be reported earlier. Called after a play goes through, and on
    /// launch.
    func flushPendingScrobbles() async {
        var sent: [PendingScrobbles.Entry] = []
        for entry in pendingScrobbles.all {
            guard await submit(entry) else { break }
            sent.append(entry)
        }
        pendingScrobbles.remove(sent)
    }

    private func resolve(_ trackId: String) async -> (JellyfinClient, String)? {
        guard let (serverId, songId) = TrackID.parse(trackId), let client = clients[serverId] else { return nil }
        return (client, songId)
    }

    // MARK: - Favorites

    /// Remembers favorites from loaded songs, so every screen shows them.
    func learn(songs: [Song]) {
        guard let serverId = activeServerId else { return }
        for song in songs { note(TrackID.make(serverId: serverId, itemId: song.id), isFavorite: song.isFavorite) }
    }

    func learn(albums: [Album]) {
        guard let serverId = activeServerId else { return }
        for album in albums { note(TrackID.make(serverId: serverId, itemId: album.id), isFavorite: album.isFavorite) }
    }

    func learn(artists: [Artist]) {
        guard let serverId = activeServerId else { return }
        for artist in artists { note(TrackID.make(serverId: serverId, itemId: artist.id), isFavorite: artist.isFavorite) }
    }

    private func note(_ compositeId: String, isFavorite: Bool) {
        if isFavorite { favoriteIds.insert(compositeId) } else { favoriteIds.remove(compositeId) }
    }

    func isFavorite(_ compositeId: String) -> Bool {
        favoriteIds.contains(compositeId)
    }

    /// Flips the favorite at once and puts it back if the server refuses. Jellyfin treats
    /// songs, albums and artists alike.
    func toggleFavorite(_ compositeId: String) async throws {
        guard let (client, itemId) = await resolve(compositeId) else { return }
        let adding = !favoriteIds.contains(compositeId)
        note(compositeId, isFavorite: adding)
        do {
            try await client.setFavorite(itemId, adding)
        } catch {
            note(compositeId, isFavorite: !adding)
            throw error
        }
    }

    /// The playing track may have come from a screen that didn't know its favorite state.
    func refreshState(trackId: String) async {
        guard let (client, songId) = await resolve(trackId),
              let song = try? await client.song(id: songId),
              let serverId = TrackID.parse(trackId)?.serverId
        else { return }
        note(TrackID.make(serverId: serverId, itemId: song.id), isFavorite: song.isFavorite)
    }

    func compositeId(_ itemId: String) -> String? {
        activeServerId.map { TrackID.make(serverId: $0, itemId: itemId) }
    }

    // MARK: - Lyrics

    func lyrics(for track: Track) async throws -> Lyrics? {
        guard let (client, songId) = await resolve(track.id) else { return nil }
        return try await client.lyrics(songId: songId)
    }

    // MARK: - Instant mix

    /// Plays songs like the given song, album or artist, picked by the server.
    func playInstantMix(itemId: String) {
        guard let client = activeClient else { return }
        perform {
            let songs = try await client.instantMix(itemId: itemId)
            self.learn(songs: songs)
            self.play(songs, containerId: "mix:\(itemId)")
        }
    }

    // MARK: - Downloads

    func download(album: Album, songs: [Song]) {
        guard let serverId = activeServerId else { return }
        downloads.download(album: album, songs: songs, serverId: serverId)
        prefetchCovers([album.coverArt ?? album.id] + songs.compactMap { $0.coverArt ?? $0.albumId }, serverId: serverId)
    }

    func download(playlist: Playlist, songs: [Song]) {
        guard let serverId = activeServerId else { return }
        downloads.download(playlist: playlist, songs: songs, serverId: serverId)
        prefetchCovers([playlist.coverArt].compactMap { $0 } + songs.compactMap { $0.coverArt ?? $0.albumId }, serverId: serverId)
    }

    func download(songs: [Song]) {
        guard let serverId = activeServerId else { return }
        downloads.download(songs: songs, serverId: serverId)
        prefetchCovers(songs.compactMap { $0.coverArt ?? $0.albumId }, serverId: serverId)
    }

    /// Covers at the sizes the screens ask for, so a downloaded album looks the same offline.
    private func prefetchCovers(_ coverIds: [String], serverId: UUID) {
        let covers = covers
        let ids = Array(Set(coverIds)).map { TrackID.make(serverId: serverId, itemId: $0) }
        Task.detached(priority: .utility) {
            for id in ids {
                for size in [120, 300, 600, 1000] { _ = await covers.image(artworkId: id, size: size) }
            }
        }
    }

    /// Plays downloaded songs, each from the server it came from, whichever is selected.
    func play(downloaded: [DownloadManager.DownloadedTrack], startTrackId: String? = nil, shuffled: Bool = false, containerId: String? = nil) {
        let tracks = downloaded.compactMap { item -> Track? in
            guard let serverId = TrackID.parse(item.trackId)?.serverId else { return nil }
            return item.song.track(serverId: serverId)
        }
        guard !tracks.isEmpty else { return }
        engine.setShuffled(shuffled)
        Task { await engine.play(tracks: tracks, startTrackId: startTrackId, containerId: containerId) }
    }

    private func rebuildClients() async {
        clients = Dictionary(uniqueKeysWithValues: servers.map { record in
            (record.id, JellyfinClient(
                host: record.host, session: record.session, libraryId: record.libraryId,
                clientInfo: Self.clientInfo, urlSession: Self.session, cache: responseCache, offline: offlineSwitch
            ))
        })
        await registry.set(clients)
    }
}

enum AddServerError: LocalizedError {
    case invalidAddress, rejected, unreachable, notJellyfin

    var errorDescription: String? {
        switch self {
        case .invalidAddress: String(localized: "That doesn't look like a server address.")
        case .rejected: String(localized: "The server didn't accept that username and password.")
        case .unreachable: String(localized: "Couldn't reach the server. Check the address, and that this phone can reach it.")
        case .notJellyfin: String(localized: "There is a server at that address, but it doesn't answer like Jellyfin.")
        }
    }
}

extension Error {
    /// A short sentence for a failed request.
    var userMessage: String {
        guard let error = self as? JellyfinClient.JellyfinError else {
            return String(localized: "Something went wrong.")
        }
        switch error {
        case .unauthorized:
            return String(localized: "The server no longer accepts this sign-in. Sign in again in Settings.")
        case .forbidden:
            return String(localized: "This account isn't allowed to do that.")
        case .notFound:
            return String(localized: "The server doesn't have that any more.")
        case .http(let code):
            return String(localized: "The server returned an error (\(code)).")
        case .decoding:
            return String(localized: "The server's answer couldn't be read.")
        case .network:
            return String(localized: "Couldn't reach the server.")
        case .offline:
            return String(localized: "Not available offline.")
        }
    }
}

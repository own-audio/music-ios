import Foundation
import OSLog
import Observation
import UIKit
import MusicEngine
import MusicLibrary
import enum OwnAudioKit.OwnAudioError

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
        didSet {
            UserDefaults.standard.set(activeServerId?.uuidString, forKey: Self.activeServerKey)
            if activeServerId != oldValue {
                followLibraryChanges()
                Task { await refreshConcertsAvailable() }
            }
        }
    }

    /// Whether the active server keeps concerts; Library shows them only then. Remembered per
    /// server, so they stay listed offline.
    var concertsAvailable = false
    /// Engine track ids of the concerts played this session: their songs are loaded as they
    /// start, and where the listener is goes to the server.
    var concertTrackIds: Set<String> = []
    var concertPositionTask: Task<Void, Never>?

    let engine: PlaybackEngine
    let playbackSettings: PlaybackSettingsStore
    let equalizer: EqualizerStore
    let covers: CoverArtLoader
    let resumeStore: ResumeStore
    let downloads: DownloadManager

    /// Each server's whole library on the phone, once synced.
    private(set) var catalogues: [UUID: Catalogue] = [:]
    private(set) var syncingCatalogues: Set<UUID> = []
    private var resyncRequested: Set<UUID> = []
    /// Following the active server's library changes (`followLibraryChanges`).
    private var liveUpdates: Task<Void, Never>?
    /// False until a scene of the app is on screen: a launch by CarPlay or in the background
    /// must not open the live-updates stream (`followLibraryChanges`).
    private var isInForeground = false
    /// The queue in the player when the app last went away, shown in the mini player until it
    /// is played again; nil while something is loaded.
    private(set) var lastQueue: LastQueue?
    @ObservationIgnored private var lastSavedTrackId: String?
    private(set) var catalogueErrors: [UUID: String] = [:]
    private let catalogueStore = CatalogueStore()
    /// An older catalogue is refreshed; a library rarely changes faster than that, and the
    /// screens online always ask the server anyway.
    private static let catalogueMaxAge: TimeInterval = 6 * 3600
    /// For a library kept from a server's change feed.
    private static let fedCatalogueMaxAge: TimeInterval = 10 * 60

    /// Offline, show the whole library (what isn't downloaded greyed out) rather than only the
    /// downloads.
    var offlineShowsWholeLibrary: Bool {
        didSet { UserDefaults.standard.set(offlineShowsWholeLibrary, forKey: Self.offlineWholeLibraryKey) }
    }

    /// Favorite songs, albums and artists, as composite ids (`TrackID`), learned from whatever
    /// the screens have loaded and kept current when the listener changes one.
    private(set) var favoriteIds: Set<String> = []
    /// Ratings 1–5 by composite id, learned the same way, where the server has ratings.
    private(set) var ratings: [String: Int] = [:]

    /// A failed action (favorite, rating, playlist edit), shown once as an alert by `RootView`.
    var actionError: String?

    /// Runs a user action and reports a failure in the shared alert.
    func perform(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch {
                Logger.app.error("action failed: \(String(describing: error), privacy: .public)")
                actionError = error.userMessage
                // The address in use may have stopped working (left home, VPN down).
                if case SourceError.network = error { Task { await chooseAddresses() } }
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
        downloadedOnly || !network.isConnected || Self.isSimulatingOffline || isOnMobileDataDownloadsOnly
    }

    /// The listener chose it, rather than the network being gone.
    var isOfflineByChoice: Bool { (downloadedOnly || isOnMobileDataDownloadsOnly) && network.isConnected && !Self.isSimulatingOffline }

    /// "Downloaded only" on mobile data, and the phone is on mobile data now.
    var isOnMobileDataDownloadsOnly: Bool {
        mobileData == .downloadedOnly && (network.isExpensive || Self.isSimulatingMobileData)
    }

    private func applyOfflineState() {
        let wasOffline = offlineSwitch.isOn
        offlineSwitch.isOn = isOffline
        engine.requiresLocalFiles = isOffline
        if wasOffline != isOffline { followLibraryChanges() }
        // Back online by choice (Offline Mode off, or Wi-Fi again): send what waited.
        if wasOffline, !isOffline, hasLoaded {
            Task { await flushPendingChanges() }
        }
    }

    /// What to do on mobile data. Wi-Fi always streams the original; downloads are always the
    /// original.
    enum MobileData: String, CaseIterable {
        /// The original file.
        case original
        /// A smaller stream where the server makes one (`saverBitrate`).
        case saver
        /// Only what is downloaded, as if offline.
        case downloadedOnly
    }

    var mobileData: MobileData {
        didSet {
            UserDefaults.standard.set(mobileData.rawValue, forKey: Self.mobileDataKey)
            applyStreamQuality()
            applyOfflineState()
        }
    }

    /// Downloads wait for Wi-Fi; on by default, as in the books and podcasts apps.
    var downloadsWifiOnly: Bool {
        didSet {
            UserDefaults.standard.set(downloadsWifiOnly, forKey: Self.downloadsWifiOnlyKey)
            downloads.wifiOnly = downloadsWifiOnly
        }
    }

    /// Keep at Most for downloads, in bytes; nil is no limit.
    var downloadsCapBytes: Int64? {
        didSet {
            UserDefaults.standard.set(downloadsCapBytes, forKey: Self.downloadsCapKey)
            downloads.capBytes = downloadsCapBytes
        }
    }

    static let downloadsCapChoices: [Int64?] = [nil, 1, 2, 5, 10, 20, 50].map { $0.map { Int64($0) * 1_000_000_000 } }

    /// Bits per second for `saver`.
    var saverBitrate: Int {
        didSet {
            UserDefaults.standard.set(saverBitrate, forKey: Self.saverBitrateKey)
            applyStreamQuality()
        }
    }

    static let saverBitrateChoices = [320_000, 192_000, 128_000]

    /// iOS Low Data Mode caps the stream at 128 kbps whatever was chosen: the listener asked the
    /// whole phone to save data.
    private func applyStreamQuality() {
        let onMobileData = network.isExpensive || Self.isSimulatingMobileData
        var bitrate: Int? = onMobileData && mobileData == .saver ? saverBitrate : nil
        if network.isConstrained { bitrate = min(bitrate ?? 128_000, 128_000) }
        let registry = registry
        Task { await registry.setMaxBitrate(bitrate) }
    }

    /// Report playback to the server: what is playing (shown on its dashboard), and plays.
    var scrobblingEnabled: Bool {
        didSet { UserDefaults.standard.set(scrobblingEnabled, forKey: Self.scrobblingKey) }
    }

    private let store: ServerStore
    /// own.audio's token sessions, one per server for the app's lifetime (`OwnAudioSessions`).
    @ObservationIgnored private let ownAudioSessions: OwnAudioSessions
    private let registry: ClientRegistry
    private let fileCache: TrackFileCache
    /// Which way to own.audio storage works on each network (`ProxyMemory`).
    private let storageRoute: ProxyMemory
    private var sources: [UUID: any MusicSource] = [:]

    private static let activeServerKey = "activeServerId"
    private static let scrobblingKey = "scrobblingEnabled"
    private static let downloadedOnlyKey = "downloadedOnly"
    private static let deviceIdKey = "deviceId"
    private static let mobileDataKey = "mobileData"
    private static let saverBitrateKey = "saverBitrate"
    private static let offlineWholeLibraryKey = "offlineShowsWholeLibrary"
    private static let downloadsWifiOnlyKey = "downloads.wifiOnly"
    private static let downloadsCapKey = "downloads.capBytes"

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
        return ClientInfo(client: "own.audio Music", device: UIDevice.current.model, deviceId: deviceId, version: version)
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
    private let pendingChanges = PendingChanges()
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
        // A UI test starts from the defaults, whatever the previous one left switched on (an
        // Offline Mode left on spoiled the next test). As in the books and podcasts apps.
        if ProcessInfo.processInfo.arguments.contains("-uiTestReset") {
            let settings: Set<String> = [Self.scrobblingKey, Self.downloadedOnlyKey, Self.mobileDataKey, Self.saverBitrateKey, Self.offlineWholeLibraryKey]
            for key in UserDefaults.standard.dictionaryRepresentation().keys
            where settings.contains(key) || key.hasPrefix("downloads.") || key.hasPrefix("player.") {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        self.store = store
        ownAudioSessions = OwnAudioSessions(store: store)
        let registry = ClientRegistry()
        self.registry = registry
        covers = CoverArtLoader(registry: registry, offline: offlineSwitch)
        downloads = DownloadManager(registry: registry)
        // Where own.audio storage is blocked on a network (a company firewall), its files come
        // through the server's media proxy instead, for streams and downloads alike.
        let storageRoute = ProxyMemory()
        self.storageRoute = storageRoute
        downloads.storageRoute = storageRoute
        fileCache = TrackFileCache(remoteURL: { try await registry.streamURL(trackId: $0) }, session: Self.session, storageRoute: storageRoute)
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
        offlineShowsWholeLibrary = UserDefaults.standard.bool(forKey: Self.offlineWholeLibraryKey)
        let defaults = UserDefaults.standard
        mobileData = defaults.string(forKey: Self.mobileDataKey).flatMap(MobileData.init(rawValue:)) ?? .saver
        saverBitrate = defaults.integer(forKey: Self.saverBitrateKey).nonZero ?? 192_000
        downloadsWifiOnly = defaults.object(forKey: Self.downloadsWifiOnlyKey) as? Bool ?? true
        downloadsCapBytes = (defaults.object(forKey: Self.downloadsCapKey) as? Int64).flatMap { $0 > 0 ? $0 : nil }
        downloads.wifiOnly = downloadsWifiOnly
        downloads.capBytes = downloadsCapBytes
        downloads.protectedTrackId = { [weak self] in self?.engine.currentTrack?.id }
        #if DEBUG
        // UI tests: `-mobileBitrate 128000` is Saver at that rate.
        if let bitrate = defaults.integer(forKey: "mobileBitrate").nonZero {
            mobileData = .saver
            saverBitrate = bitrate
        }
        #endif
        applyOfflineState()
        applyStreamQuality()
        network.onChange = { [weak self] connected in
            guard let self else { return }
            self.storageRoute.network = self.network.signature
            self.applyOfflineState()
            self.applyStreamQuality()
            if connected {
                self.networkSettle.schedule { [weak self] in await self?.networkSettled() }
            } else {
                self.networkSettle.cancel()
            }
        }
        wireScrobbling()
        // As `isInForeground`: nothing is on screen until a scene says so (CarPlay alone never does).
        engine.isInBackground = true
        // A downloaded song plays from the phone whether or not the server can be reached.
        let files = downloads.files
        let fileCache = fileCache
        Task { await fileCache.setLocalFileLookup { files.url(for: $0) } }
    }

    /// Waits for a burst of network changes to end before acting on it.
    @ObservationIgnored private let networkSettle = Debouncer(delay: .seconds(3))
    /// A network change in the background skipped choosing addresses; coming back does it.
    @ObservationIgnored private var addressesNeedChoosing = false

    /// The phone is on a new network, and has been for a moment. In the background only what
    /// waited is sent: no library sync, and the address race only while something is in the
    /// player, whose next song has to reach the server from the new network.
    private func networkSettled() async {
        let plan = Self.afterNetworkChange(inForeground: isInForeground, playerLoaded: engine.currentTrack != nil)
        if plan.chooseAddresses {
            await chooseAddresses()
        } else {
            addressesNeedChoosing = true
        }
        await flushPendingScrobbles()
        await flushPendingChanges()
        if plan.syncLibraries { await syncCatalogues() }
    }

    nonisolated static func afterNetworkChange(inForeground: Bool, playerLoaded: Bool) -> (chooseAddresses: Bool, syncLibraries: Bool) {
        (inForeground || playerLoaded, inForeground)
    }

    /// The widget's pictures as JPEG by artwork id, so a refresh for the same covers doesn't
    /// encode them again.
    @ObservationIgnored var widgetCovers: [String: Data] = [:]
    /// The Recently Played widget's albums from the last time they were asked for.
    @ObservationIgnored var widgetAlbums: [WidgetSnapshot.Entry] = []

    /// As lists show them: own.audio servers first, then the others, each in the order added.
    var serversInOrder: [ServerRecord] {
        servers.filter { $0.kind == .ownAudio } + servers.filter { $0.kind != .ownAudio }
    }

    var activeServer: ServerRecord? {
        servers.first { $0.id == activeServerId }
    }

    var activeSource: (any MusicSource)? {
        activeServerId.flatMap { sources[$0] }
    }

    /// What the active server can do; screens hide what it can't.
    var capabilities: Capabilities { activeSource?.capabilities ?? [] }

    /// own.audio's own API for a server signed in through it; nil for other servers, and for
    /// an own.audio server still added through its Subsonic API.
    func ownAudioSource(serverId: UUID) -> OwnAudioSource? {
        sources[serverId] as? OwnAudioSource
    }

    // MARK: Devices (own.audio sessions)

    func sessions(serverId: UUID) async throws -> [DeviceSession] {
        guard let source = ownAudioSource(serverId: serverId) else { throw SourceError.unsupported }
        return try await source.sessions()
    }

    func revokeSession(serverId: UUID, id: String) async throws {
        guard let source = ownAudioSource(serverId: serverId) else { throw SourceError.unsupported }
        try await source.revokeSession(id: id)
    }

    /// Every device out, this one included: the server then needs a fresh sign-in.
    func signOutEverywhere(serverId: UUID) async throws {
        guard let source = ownAudioSource(serverId: serverId) else { throw SourceError.unsupported }
        try await source.signOutEverywhere()
        signInRefused.insert(serverId)
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
            catalogueStore.removeAll()
            LastQueue.remove()
        }
        lastQueue = LastQueue.load()
        observeQueueForRelaunch()
        servers = await store.loadAll()
        await moveOwnAudioToHTTPS()
        await addServerFromLaunchArguments()
        await rebuildClients()
        let saved = UserDefaults.standard.string(forKey: Self.activeServerKey).flatMap(UUID.init)
        activeServerId = servers.contains { $0.id == saved } ? saved : servers.first?.id
        await refreshConcertsAvailable()
        await loadCatalogues()
        hasLoaded = true
        followLibraryChanges()
        downloads.resume()
        Task {
            await chooseAddresses()
            await syncCatalogues()
        }
        await flushPendingScrobbles()
        await flushPendingChanges()
        await refreshWidget(fetch: true)
    }

    /// Finds out what kind of server is at `address` and signs in before saving anything, so a
    /// typo is caught here rather than on the first screen that fails. Jellyfin is asked first
    /// (it answers a public info request); otherwise the address is tried as a Subsonic server.
    /// For Jellyfin only the session token is saved, never the password.
    func addServer(address: String, username: String, password: String, name: String) async throws {
        let address = ServerSetup.ownAudioAPIAddress(address)
        if let (host, info) = try await findJellyfin(address) {
            let session: JellyfinSession
            do {
                session = try await ServerSetup.jellyfinSignIn(
                    host: host, username: username, password: password, clientInfo: Self.clientInfo, urlSession: Self.session
                )
            } catch SourceError.signInRejected {
                throw AddServerError.rejected
            } catch SourceError.network {
                throw AddServerError.unreachable
            }
            try await saveJellyfin(host: host, info: info, session: session, name: name)
            return
        }
        // An own.audio server answers its own discovery request too, with its identity and
        // addresses; any other Subsonic server doesn't.
        guard let (host, ownAudio) = await hostAndOwnAudioInfo(address) else { throw AddServerError.invalidAddress }
        var username = username
        var secret = password
        switch await ServerSetup.subsonicCheck(host: host, username: username, password: password, urlSession: Self.session) {
        case .ok:
            break
        case .rejected:
            // own.audio's Subsonic API takes a per-account key, not the password: with the
            // account's email and password the app fetches the key itself.
            guard let ownAudio else { throw AddServerError.rejected }
            // From 1.0.0-beta.7 through the server's own API: tokens, and two-factor sign-in.
            if await ServerSetup.ownAudioSpeaksV2(host: host, urlSession: Self.quickSession) {
                let result: OwnAudioSignInResult
                do {
                    result = try await ServerSetup.ownAudioSignIn(
                        host: host, email: username, password: password, deviceName: UIDevice.current.name, urlSession: Self.session
                    )
                } catch SourceError.signInRejected {
                    throw AddServerError.rejected
                } catch SourceError.network {
                    throw AddServerError.unreachable
                }
                try await finishOwnAudio(result, host: host, info: ownAudio, name: name)
                return
            }
            do {
                (username, secret) = try await ServerSetup.ownAudioSubsonicKey(host: host, email: username, password: password, urlSession: Self.session)
            } catch SourceError.signInRejected {
                throw AddServerError.rejected
            } catch {
                throw AddServerError.unreachable
            }
            guard await ServerSetup.subsonicCheck(host: host, username: username, password: secret, urlSession: Self.session) == .ok else {
                throw AddServerError.rejected
            }
        case .unreachable:
            throw AddServerError.unreachable
        }
        var record = ServerRecord(
            displayName: displayName(name, fallback: ownAudio != nil ? "own.audio" : (host.host ?? address)),
            kind: ownAudio != nil ? .ownAudio : .subsonic, host: host,
            auth: .subsonic(username: username, password: secret), serverId: ownAudio?.id
        )
        record.learn(ownAudio?.addresses ?? [])
        try await save(record)
    }

    /// How someone signs in to an own.audio server without a password.
    enum OwnAudioSignIn {
        /// Sign in with Apple: the identity token, and the name Apple gives only the first time.
        case apple(identityToken: String, fullName: String?)
        /// Google: the ID token for this app's iOS client.
        case google(idToken: String)
    }

    /// An own.audio server added with Apple or Google: the server exchanges the provider's token
    /// for the API's tokens. A server older than 1.0.0-beta.7 gives a session instead, and the
    /// app fetches the account's Subsonic key with it; only the key is kept then.
    func addOwnAudioServer(address: String, signIn: OwnAudioSignIn, name: String) async throws {
        let address = ServerSetup.ownAudioAPIAddress(address)
        guard var host = ServerSetup.subsonicHost(address) else { throw AddServerError.invalidAddress }
        let info: ServerSetup.OwnAudioInfo
        do {
            if let (secure, found) = await hostAndOwnAudioInfo(address), let found {
                host = secure
                info = found
            } else {
                info = try await ServerSetup.ownAudioInfo(at: host, urlSession: Self.quickSession)
            }
        } catch SourceError.unreadable {
            throw AddServerError.notOwnAudio
        } catch {
            throw AddServerError.unreachable
        }
        if await ServerSetup.ownAudioSpeaksV2(host: host, urlSession: Self.quickSession) {
            let (provider, idToken, fullName): (String, String, String?) = switch signIn {
            case .apple(let identityToken, let fullName): ("apple", identityToken, fullName)
            case .google(let idToken): ("google", idToken, nil)
            }
            guard provider == "apple" ? info.signInWithApple : info.signInWithGoogle else { throw AddServerError.providerOff }
            let result = try await ServerSetup.ownAudioSignIn(
                host: host, provider: provider, idToken: idToken, fullName: fullName, deviceName: UIDevice.current.name, urlSession: Self.session
            )
            try await finishOwnAudio(result, host: host, info: info, name: name)
            return
        }
        let token: String
        switch signIn {
        case .apple(let identityToken, let fullName):
            guard info.signInWithApple else { throw AddServerError.providerOff }
            token = try await ServerSetup.ownAudioAppleSignIn(
                host: host, identityToken: identityToken, fullName: fullName,
                deviceName: UIDevice.current.name, urlSession: Self.session
            )
        case .google(let idToken):
            guard info.signInWithGoogle else { throw AddServerError.providerOff }
            token = try await ServerSetup.ownAudioGoogleSignIn(
                host: host, idToken: idToken, deviceName: UIDevice.current.name, urlSession: Self.session
            )
        }
        let (username, key) = try await ServerSetup.ownAudioSubsonicKey(host: host, token: token, urlSession: Self.session)
        guard await ServerSetup.subsonicCheck(host: host, username: username, password: key, urlSession: Self.session) == .ok else {
            throw AddServerError.rejected
        }
        var record = ServerRecord(
            displayName: displayName(name, fallback: "own.audio"), kind: .ownAudio, host: host,
            auth: .subsonic(username: username, password: key), serverId: info.id
        )
        record.learn(info.addresses)
        try await save(record)
    }

    /// An own.audio sign-in waiting for its second factor (the account has two-factor sign-in on).
    struct PendingTwoFactor: Identifiable {
        let id = UUID()
        let host: URL
        let mfaToken: String
        let name: String
        let info: ServerSetup.OwnAudioInfo
    }

    /// Set while the code is asked for; the sign-in screens show `TwoFactorView` for it.
    private(set) var pendingTwoFactor: PendingTwoFactor?

    func cancelTwoFactor() {
        pendingTwoFactor = nil
        replacing = nil
    }

    /// The second step, with the authenticator's code or a recovery code.
    func finishTwoFactor(code: String) async throws {
        guard let pending = pendingTwoFactor else { return }
        let result: OwnAudioSignInResult
        do {
            result = try await ServerSetup.ownAudioFinishTwoFactor(
                host: pending.host, mfaToken: pending.mfaToken, code: code.trimmingCharacters(in: .whitespaces), urlSession: Self.session
            )
        } catch SourceError.signInRejected {
            throw AddServerError.wrongCode
        } catch SourceError.server {
            throw AddServerError.wrongCode
        }
        pendingTwoFactor = nil
        try await finishOwnAudio(result, host: pending.host, info: pending.info, name: pending.name)
    }

    /// Saves a server signed in through own.audio's own API, or asks for the second factor.
    private func finishOwnAudio(_ result: OwnAudioSignInResult, host: URL, info: ServerSetup.OwnAudioInfo, name: String) async throws {
        switch result {
        case .twoFactor(let mfaToken):
            pendingTwoFactor = PendingTwoFactor(host: host, mfaToken: mfaToken, name: name, info: info)
            throw AddServerError.twoFactorNeeded
        case .signedIn(let username, let tokens):
            // Tokens only: the API answers everything the app needs, so no Subsonic key is fetched.
            var record = ServerRecord(
                displayName: displayName(name, fallback: "own.audio"), kind: .ownAudio, host: host,
                auth: .ownAudio(username: username, key: nil, tokens: tokens), serverId: info.id
            )
            record.learn(info.addresses)
            try await save(record)
        }
    }

    /// The public own.audio demo, signed in with the account it offers to anyone.
    static let demoServer = URL(string: "https://demopi.own.audio")!

    func addDemoServer() async throws {
        let account: (email: String, password: String)
        do {
            account = try await ServerSetup.ownAudioDemoAccount(host: Self.demoServer, urlSession: Self.session)
        } catch {
            throw AddServerError.unreachable
        }
        try await addServer(address: Self.demoServer.absoluteString, username: account.email, password: account.password, name: "own.audio demo")
    }

    /// The Jellyfin server at `address`, if there is one. Without a scheme, each likely address
    /// is tried in turn. Nil when nothing there answers like Jellyfin; throws only for an
    /// address that can't be one.
    func findJellyfin(_ address: String) async throws -> (URL, JellyfinServerInfo)? {
        let candidates = ServerSetup.jellyfinCandidates(address)
        guard !candidates.isEmpty else { throw AddServerError.invalidAddress }
        for host in candidates {
            if let info = try? await ServerSetup.jellyfinInfo(host: host, urlSession: Self.quickSession) {
                return (host, info)
            }
        }
        return nil
    }

    /// For trying addresses: a wrong guess shouldn't hold the next one up for long.
    private static let quickSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 6
        return URLSession(configuration: configuration)
    }()

    /// Saves a signed-in Jellyfin server (password or Quick Connect) and makes it the one shown.
    func saveJellyfin(host: URL, info: JellyfinServerInfo, session: JellyfinSession, name: String) async throws {
        var record = ServerRecord(
            displayName: displayName(name, fallback: info.serverName.isEmpty ? (host.host ?? "") : info.serverName),
            kind: .jellyfin, host: host, auth: .jellyfin(session: session), serverId: info.id
        )
        record.learn(info.localAddress.flatMap(URL.init(string:)).map { [ServerAddress(url: $0, origin: .server)] } ?? [])
        try await save(record)
    }

    private func displayName(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    // MARK: - Signing in again

    /// Servers that refused the saved sign-in (a password changed, a session ended, a demo
    /// that resets every night); their detail screen offers to sign in again.
    private(set) var signInRefused: Set<UUID> = []

    /// While set, a successful sign-in replaces this server's sign-in instead of adding a server.
    private var replacing: UUID?

    /// Signs in to a saved server again, as when it was added (two-factor included). The server
    /// keeps its id, so its downloads, library on the phone and addresses stay.
    func signInAgain(serverId: UUID, username: String, password: String) async throws {
        guard let server = servers.first(where: { $0.id == serverId }) else { return }
        replacing = serverId
        do {
            try await addServer(address: server.host.absoluteString, username: username, password: password, name: server.displayName)
            replacing = nil
        } catch {
            // The two-factor screen finishes it; anything else ends the attempt.
            if !error.isTwoFactorNeeded { replacing = nil }
            throw error
        }
    }

    /// The same with Apple or Google, for an own.audio server whose account signs in that way.
    func signInAgain(serverId: UUID, with signIn: OwnAudioSignIn) async throws {
        guard let server = servers.first(where: { $0.id == serverId }) else { return }
        replacing = serverId
        do {
            try await addOwnAudioServer(address: server.host.absoluteString, signIn: signIn, name: server.displayName)
            replacing = nil
        } catch {
            if !error.isTwoFactorNeeded { replacing = nil }
            throw error
        }
    }

    /// The server address for what was typed, and own.audio's discovery answer when it is one.
    /// Without http:// or https://, own.audio is tried over https first. It used to get http://
    /// in front: own.audio redirects that to https, iOS repeats a POST after a redirect as a
    /// GET, and so every sign-in and token refresh came back 405 — besides going out unencrypted.
    /// A server that answers only over http (a home Navidrome, say) still gets http.
    func hostAndOwnAudioInfo(_ address: String) async -> (URL, ServerSetup.OwnAudioInfo?)? {
        guard let plain = ServerSetup.subsonicHost(address) else { return nil }
        let typed = address.trimmingCharacters(in: .whitespaces).lowercased()
        if !typed.hasPrefix("http://"), !typed.hasPrefix("https://"),
           var parts = URLComponents(url: plain, resolvingAgainstBaseURL: false) {
            parts.scheme = "https"
            if let secure = parts.url, let info = try? await ServerSetup.ownAudioInfo(at: secure, urlSession: Self.quickSession) {
                return (secure, info)
            }
        }
        return (plain, try? await ServerSetup.ownAudioInfo(at: plain, urlSession: Self.quickSession))
    }

    /// own.audio servers saved with http:// by the bug above move to https, when the same server
    /// (by its id) answers there; until then their token refreshes fail.
    private func moveOwnAudioToHTTPS() async {
        for server in servers where server.kind == .ownAudio && server.host.scheme == "http" {
            guard var parts = URLComponents(url: server.host, resolvingAgainstBaseURL: false) else { continue }
            parts.scheme = "https"
            guard let secure = parts.url,
                  let info = try? await ServerSetup.ownAudioInfo(at: secure, urlSession: Self.quickSession),
                  server.serverId == nil || info.id == server.serverId else { continue }
            var moved = server
            moved.host = secure
            ownAudioSessions.forget(server.id)
            try? await update(moved)
            Logger.app.info("own.audio server moved to https")
        }
    }

    /// Which providers the own.audio server at a typed address offers, for showing only their
    /// buttons; nothing for an address that isn't own.audio. Without a scheme, https then http.
    /// A check the network didn't answer is tried once more with more time, and is logged: on a
    /// slow phone connection the buttons used to stay hidden with nothing said. own.audio's own
    /// hosted service always offers Google, so its addresses show that button even then.
    func ownAudioProviders(address: String) async -> (apple: Bool, google: Bool) {
        let api = ServerSetup.ownAudioAPIAddress(address)
        let candidates = api.contains("://") ? [api] : ["https://\(api)", "http://\(api)"]
        for session in [Self.quickSession, Self.session] {
            var unreachable = false
            for text in candidates {
                guard let url = URL(string: text), url.host() != nil else { continue }
                do {
                    let info = try await ServerSetup.ownAudioInfo(at: url, urlSession: session)
                    return (info.signInWithApple, info.signInWithGoogle)
                } catch SourceError.unreadable {
                    continue
                } catch {
                    unreachable = true
                    Logger.network.error("sign-in options from \(url.host() ?? "", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            guard unreachable, !Task.isCancelled else { break }
        }
        let hosted = ["https://api.own.audio", "https://api-canary.own.audio"].contains(api)
            || ["api.own.audio", "api-canary.own.audio"].contains(api.lowercased().replacingOccurrences(of: "https://", with: ""))
        return (false, hosted)
    }

    /// Which providers an own.audio server offers, for showing only their buttons.
    func ownAudioProviders(serverId: UUID) async -> (apple: Bool, google: Bool) {
        guard let server = servers.first(where: { $0.id == serverId }),
              let info = try? await ServerSetup.ownAudioInfo(at: server.host, urlSession: Self.quickSession)
        else { return (false, false) }
        return (info.signInWithApple, info.signInWithGoogle)
    }

    /// Puts a fresh sign-in on the server being signed in to again; refuses one for another server.
    private func replaceSignIn(of id: UUID, with record: ServerRecord) async throws {
        guard var server = servers.first(where: { $0.id == id }) else { return }
        let sameServer = server.kind == record.kind
            && (server.serverId != nil && record.serverId != nil ? server.serverId == record.serverId : server.host == record.host)
        guard sameServer else { throw AddServerError.differentServer }
        server.auth = record.auth
        server.serverId = record.serverId ?? server.serverId
        server.learn(record.addresses.filter { $0.origin == .server })
        // A new token session for the new tokens; the old one would refresh with a dead token.
        ownAudioSessions.forget(id)
        signInRefused.remove(id)
        catalogueErrors[id] = nil
        try await update(server, signIn: true)
        Task {
            await chooseAddresses()
            await syncCatalogues(force: true)
        }
    }

    private func save(_ record: ServerRecord) async throws {
        if let id = replacing {
            replacing = nil
            return try await replaceSignIn(of: id, with: record)
        }
        try await store.add(record)
        servers.append(record)
        await rebuildClients()
        activeServerId = record.id
        // A server that named a home address is worth switching to at once.
        Task {
            await chooseAddresses()
            await syncCatalogues()
        }
    }

    /// Deletes the own.audio account on the server, then the server from this iPhone. The
    /// server's last admin can't: the server answers 400.
    func deleteAccount(serverId id: UUID) async throws {
        guard let client = ownAudioSource(serverId: id)?.client else { return }
        do {
            try await client.deleteAccount()
        } catch OwnAudioError.http(400) {
            throw AccountDeletionError.lastAdmin
        } catch OwnAudioError.http(403) {
            throw AccountDeletionError.refused
        }
        try await removeServer(id: id)
    }

    enum AccountDeletionError: LocalizedError {
        case lastAdmin
        /// The public demo's shared account, which nobody may change.
        case refused
        var errorDescription: String? {
            switch self {
            case .lastAdmin: String(localized: "This is the server's only admin account. Make someone else an admin on the server first, or delete the account there.")
            case .refused: String(localized: "The server doesn't let this account be deleted. A shared demo account stays for everyone.")
            }
        }
    }

    func removeServer(id: UUID) async throws {
        // Ends the session on the server too, so the device leaves its dashboard.
        if let source = sources[id] { Task.detached { await source.signOut() } }
        ownAudioSessions.forget(id)
        try await store.remove(id: id)
        servers.removeAll { $0.id == id }
        downloads.removeAll(serverId: id)
        catalogueStore.remove(serverId: id)
        catalogues[id] = nil
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
        let saved = try await store.update(record)
        if let index = servers.firstIndex(where: { $0.id == serverId }) { servers[index] = saved }
        responseCache.removeAll()
        await rebuildClients()
    }

    /// A server's music libraries, listed without the current choice applied.
    func musicLibraries(serverId: UUID) async -> [MusicLibraryInfo] {
        guard var record = servers.first(where: { $0.id == serverId }) else { return [] }
        record.libraryId = nil
        return (try? await record.makeSource(sourceEnvironment).musicLibraries()) ?? []
    }

    func selectServer(id: UUID) {
        guard servers.contains(where: { $0.id == id }) else { return }
        activeServerId = id
    }

    func checkConnection(id: UUID) async -> ConnectionStatus {
        guard let source = sources[id] else { return .unreachable }
        return await source.checkConnection()
    }

    /// The last "Check Now" of each server: what it found and when.
    private(set) var connectionChecks: [UUID: (status: ConnectionStatus, at: Date)] = [:]
    private(set) var checkingConnections: Set<UUID> = []

    /// Picks the address again, then asks the server whether it accepts the sign-in.
    func checkNow(id: UUID) async {
        guard !checkingConnections.contains(id) else { return }
        checkingConnections.insert(id)
        await chooseAddresses()
        let status = await checkConnection(id: id)
        connectionChecks[id] = (status, Date())
        if status == .rejected { signInRefused.insert(id) } else if status == .ok { signInRefused.remove(id) }
        checkingConnections.remove(id)
    }

    /// Plays `songs` from the active server, starting at `startSongId` or the first song.
    /// `containerId` ("album:…") lets the engine remember where in it listening stopped.
    /// Offline, only the downloaded ones; a tapped song that isn't downloaded starts the list at
    /// the next one that is.
    /// "Play Next" and "Add to Queue": into the queue playing now, or played at once when
    /// nothing is. Offline, only downloaded songs go in.
    func enqueue(_ songs: [Song], next: Bool) {
        guard let serverId = activeServerId else { return }
        let songs = isOffline ? songs.filter { downloads.isDownloaded(TrackID.make(serverId: serverId, itemId: $0.id)) } : songs
        guard !songs.isEmpty else {
            actionError = String(localized: "You're offline, and none of these songs are downloaded.")
            return
        }
        guard engine.currentTrack != nil else {
            play(songs)
            return
        }
        let tracks = songs.map { $0.track(serverId: serverId) }
        if next { engine.playNext(tracks) } else { engine.addToQueue(tracks) }
        Haptics.impact(.light)
    }

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
        rememberConcerts(songs, serverId: serverId)
        engine.setShuffled(shuffled)
        Task {
            let first = startSongId.flatMap { id in songs.first { $0.id == id } } ?? (shuffled ? nil : songs.first)
            let resumeAt = await concertResumePosition(first)
            await engine.play(
                tracks: tracks,
                startTrackId: (first?.id ?? startSongId).map { TrackID.make(serverId: serverId, itemId: $0) },
                startPositionSecs: resumeAt,
                containerId: containerId.map { "\(serverId.uuidString)|\($0)" }
            )
        }
    }

    /// Debug builds only: `-debugServerHost <url> -debugServerUser <name> -debugServerPassword <secret>`
    /// adds that server at launch if it isn't there yet, so a simulator can be handed to someone
    /// already connected. A Subsonic server whose password changed (a demo server that issues a
    /// new key each day) gets the new one.
    private func addServerFromLaunchArguments() async {
        #if DEBUG
        let defaults = UserDefaults.standard
        guard let address = defaults.string(forKey: "debugServerHost"),
              let username = defaults.string(forKey: "debugServerUser"),
              let password = defaults.string(forKey: "debugServerPassword")
        else { return }
        let hosts = Set(ServerSetup.jellyfinCandidates(address) + [ServerSetup.subsonicHost(address)].compactMap { $0 })
        if let index = servers.firstIndex(where: { hosts.contains($0.host) && $0.auth.username == username }) {
            guard case .subsonic(_, let saved) = servers[index].auth, saved != password else { return }
            servers[index].auth = .subsonic(username: username, password: password)
            try? await store.update(servers[index])
            return
        }
        try? await addServer(address: address, username: username, password: password, name: defaults.string(forKey: "debugServerName") ?? "")
        #endif
    }

    // MARK: - Scrobbling

    private func wireScrobbling() {
        let scrobbler = ScrobbleTracker { [weak self] event in self?.report(event) }
        self.scrobbler = scrobbler
        engine.onPlaybackStarted = { [weak self] track, position in
            self?.concertStarted(track)
            guard let self, self.scrobblingEnabled else { return }
            scrobbler.started(key: track.id, durationSecs: track.durationSecs)
            self.startScrobbleTicks()
            Task { await self.reportSession(.start, trackId: track.id, position: position) }
        }
        engine.onPlaybackStopped = { [weak self] track, position, reason in
            self?.concertStopped(track, at: position, reason: reason)
            // Paused or stopped, nothing moves: the stop report below tells the server, and the
            // loop starts again with the next play. Every 15 s it woke the radio for nothing.
            self?.stopScrobbleTicks()
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
        guard scrobblingEnabled, let (source, songId) = await resolve(trackId) else { return }
        do {
            switch event {
            case .start:
                try await source.reportNowPlaying(songId: songId, positionSecs: position)
                if source.capabilities.contains(.countsPlaysFromReports) { reportedLive.insert(trackId) }
            case .progress:
                try await source.reportProgress(songId: songId, positionSecs: position, isPaused: !engine.isPlaying)
            case .stopped:
                try await source.reportStopped(songId: songId, positionSecs: position)
            }
        } catch {}
    }

    /// Counts a play while it is still playing, so it isn't lost if the app is killed. Runs
    /// only while playing: `onPlaybackStopped` ends it, `onPlaybackStarted` starts it again.
    private func startScrobbleTicks() {
        guard scrobbleTickTask == nil else { return }
        scrobbleTickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled else { return }
                guard self.engine.isPlaying else {
                    self.scrobbleTickTask = nil
                    return
                }
                self.scrobbler?.tick()
                // Without a report now and then the server takes the session for ended.
                if let track = self.engine.currentTrack {
                    await self.reportSession(.progress, trackId: track.id, position: self.engine.currentTime)
                }
            }
        }
    }

    private func stopScrobbleTicks() {
        scrobbleTickTask?.cancel()
        scrobbleTickTask = nil
    }

    private func report(_ event: ScrobbleTracker.Event) {
        Task {
            switch event {
            case .nowPlaying:
                // Covered by the session report sent when playback started.
                break
            case .played(let trackId, let startedAt, let heardSecs):
                guard !reportedLive.contains(trackId) else { return }
                let entry = PendingScrobbles.Entry(trackId: trackId, startedAt: startedAt, heardSecs: heardSecs, countedAt: Date())
                if await submit(entry) {
                    await flushPendingScrobbles()
                } else {
                    pendingScrobbles.add(entry)
                }
            }
        }
    }

    private func submit(_ entry: PendingScrobbles.Entry) async -> Bool {
        guard let (source, songId) = await resolve(entry.trackId) else {
            // The server was removed; there's nowhere to report it.
            return true
        }
        if let batched = source as? any BatchedOfflineEdits, let edit = entry.edit(songId: songId) {
            do {
                try await batched.push([edit])
                return true
            } catch SourceError.network, SourceError.offline {
                return false
            } catch {
                // Signed in the old way, or refused: reported as below.
            }
        }
        do {
            try await source.reportPlayed(songId: songId, at: entry.startedAt)
            return true
        } catch {
            return false
        }
    }

    /// Sends plays that couldn't be reported earlier. Called after a play goes through, and on
    /// launch. A server that takes them in one request gets them so, the rest one at a time.
    func flushPendingScrobbles() async {
        let entries = pendingScrobbles.all
        var sent: [PendingScrobbles.Entry] = []
        var batched: Set<UUID> = []
        let byServer = Dictionary(grouping: entries) { TrackID.parse($0.trackId)?.serverId }
        for case let (serverId?, plays) in byServer {
            guard let source = sources[serverId] as? any BatchedOfflineEdits else { continue }
            let edits = plays.compactMap { play in
                TrackID.parse(play.trackId).flatMap { play.edit(songId: $0.itemId) }.map { (play, $0) }
            }
            guard !edits.isEmpty else { continue }
            do {
                try await source.push(edits.map(\.1))
                sent += edits.map(\.0)
                batched.insert(serverId)
            } catch SourceError.network, SourceError.offline {
                batched.insert(serverId)
            } catch {
                // Signed in the old way, or refused: one at a time below.
            }
        }
        for entry in entries where !sent.contains(entry) {
            if let serverId = TrackID.parse(entry.trackId)?.serverId, batched.contains(serverId), entry.heardSecs != nil { continue }
            guard await submit(entry) else { break }
            sent.append(entry)
        }
        pendingScrobbles.remove(sent)
    }

    func resolve(_ trackId: String) async -> ((any MusicSource), String)? {
        guard let (serverId, songId) = TrackID.parse(trackId), let source = sources[serverId] else { return nil }
        return (source, songId)
    }

    // MARK: - Favorites and ratings

    /// Remembers favorites and ratings from loaded songs, so every screen shows them.
    func learn(songs: [Song]) {
        guard let serverId = activeServerId else { return }
        for song in songs {
            let id = TrackID.make(serverId: serverId, itemId: song.id)
            note(id, isFavorite: song.isFavorite)
            ratings[id] = song.rating
        }
    }

    func learn(albums: [Album]) {
        guard let serverId = activeServerId else { return }
        for album in albums {
            let id = TrackID.make(serverId: serverId, itemId: album.id)
            note(id, isFavorite: album.isFavorite)
            ratings[id] = album.rating
        }
    }

    func learn(artists: [Artist]) {
        guard let serverId = activeServerId else { return }
        for artist in artists { note(TrackID.make(serverId: serverId, itemId: artist.id), isFavorite: artist.isFavorite) }
    }

    private func note(_ compositeId: String, isFavorite: Bool) {
        if isFavorite { favoriteIds.insert(compositeId) } else { favoriteIds.remove(compositeId) }
    }

    // MARK: - Sharing with the household (own.audio)

    /// Changes made here, until the library on the phone brings them back.
    private(set) var sharingChanges: [String: Sharing] = [:]

    /// own.audio signed in through its API; one signed in the old way (a Subsonic key only)
    /// has no way to its household until signed in again.
    var household: (any HouseholdSource)? {
        guard case .ownAudio(_, _, .some) = activeServer?.auth else { return nil }
        return activeSource as? any HouseholdSource
    }

    /// Whose the song is and who hears it, with any change made here.
    func sharing(of song: Song) -> Sharing? {
        sharingChanges[song.id] ?? song.sharing
    }

    /// The listener's own songs among `songs`, shared or kept to themselves at once; put back if
    /// the server refuses.
    func setShared(_ songs: [Song], _ shared: Bool) {
        guard let household else { return }
        let mine = songs.filter { sharing(of: $0)?.isMine == true }
        guard !mine.isEmpty else { return }
        let before = mine.map { ($0.id, sharingChanges[$0.id]) }
        for song in mine { sharingChanges[song.id] = shared ? .shared : .mine }
        Task {
            do {
                try await household.setShared(songIds: mine.map(\.id), shared)
            } catch {
                for (id, old) in before { sharingChanges[id] = old }
                actionError = error.userMessage
            }
        }
    }

    /// Whether the listener owns any of the artist's songs, which is all the server identifies;
    /// true when that isn't known (no library on the phone yet, or no household).
    func mayIdentify(artistId: String) -> Bool {
        guard let songs = activeCatalogue?.songs.filter({ $0.artistId == artistId }), !songs.isEmpty,
              songs.contains(where: { $0.sharing != nil })
        else { return true }
        return songs.contains { sharing(of: $0)?.isMine == true }
    }

    // MARK: - The listener's own pictures (own.audio)

    /// Covers changed here, by composite artwork id: how many times, so their views load again.
    private(set) var coverChanges: [String: Int] = [:]

    var artwork: (any ArtworkSource)? {
        guard case .ownAudio(_, _, .some) = activeServer?.auth else { return nil }
        return activeSource as? any ArtworkSource
    }

    enum ArtworkTarget {
        /// The listener's own songs among these; an album's when `albumId` is set.
        case songs([Song], albumId: String?)
        case artist(Artist)
        case playlist(String)
    }

    /// Uploads `image` as the target's picture, then shows it everywhere at once.
    func setArtwork(_ target: ArtworkTarget, image: Data, contentType: String) async throws {
        guard let artwork, let serverId = activeServerId else { return }
        var changed: [String] = []
        switch target {
        case .songs(let songs, let albumId):
            let mine = songs.filter { sharing(of: $0)?.isMine == true }
            guard !mine.isEmpty else { return }
            try await artwork.setCover(songIds: mine.map(\.id), albumId: albumId, image: image, contentType: contentType)
            changed = mine.map(\.id) + mine.compactMap(\.coverArt) + mine.compactMap(\.albumId) + [albumId].compactMap { $0 }
        case .artist(let artist):
            try await artwork.setPicture(artist: artist, image: image, contentType: contentType)
            changed = [artist.id] + [artist.coverArt].compactMap { $0 }
        case .playlist(let id):
            try await artwork.setCover(playlistId: id, image: image, contentType: contentType)
            changed = [id]
        }
        for id in Set(changed) {
            let composite = TrackID.make(serverId: serverId, itemId: id)
            await covers.forget(artworkId: composite)
            widgetCovers[composite] = nil
            coverChanges[composite, default: 0] += 1
        }
    }

    func isFavorite(_ compositeId: String) -> Bool {
        favoriteIds.contains(compositeId)
    }

    /// Flips the favorite at once and puts it back if the server refuses. Offline, it is kept
    /// and sent when the server can be reached.
    func toggleFavorite(_ compositeId: String, kind: FavoriteKind) async throws {
        guard let (source, itemId) = await resolve(compositeId) else { return }
        let adding = !favoriteIds.contains(compositeId)
        note(compositeId, isFavorite: adding)
        if isOffline, let serverId = TrackID.parse(compositeId)?.serverId {
            pendingChanges.add(.init(serverId: serverId, itemId: itemId, change: .favorite(kind: kind.storedName, isFavorite: adding), madeAt: Date()))
            return
        }
        do {
            try await source.setFavorite(kind, id: itemId, adding)
        } catch {
            note(compositeId, isFavorite: !adding)
            throw error
        }
    }

    /// `rating` 1–5, or 0 to clear it, for a song or an album.
    func setRating(_ compositeId: String, kind: FavoriteKind, rating: Int) async throws {
        guard let (source, itemId) = await resolve(compositeId) else { return }
        let previous = ratings[compositeId]
        ratings[compositeId] = rating == 0 ? nil : rating
        if isOffline, let serverId = TrackID.parse(compositeId)?.serverId {
            pendingChanges.add(.init(serverId: serverId, itemId: itemId, change: .rated(kind: kind.storedName, rating: rating), madeAt: Date()))
            return
        }
        do {
            try await source.setRating(id: itemId, rating: rating)
        } catch {
            ratings[compositeId] = previous
            throw error
        }
    }

    /// The playing track may have come from a screen that didn't know its state.
    func refreshState(trackId: String) async {
        guard let (source, songId) = await resolve(trackId),
              let song = try? await source.song(id: songId),
              let serverId = TrackID.parse(trackId)?.serverId
        else { return }
        let id = TrackID.make(serverId: serverId, itemId: song.id)
        note(id, isFavorite: song.isFavorite)
        ratings[id] = song.rating
    }

    func compositeId(_ itemId: String) -> String? {
        activeServerId.map { TrackID.make(serverId: $0, itemId: itemId) }
    }

    /// Adds songs to a playlist on the active server; offline, kept and sent later.
    func addToPlaylist(_ playlistId: String, songIds: [String]) async throws {
        guard let serverId = activeServerId, let source = activeSource else { return }
        if isOffline {
            pendingChanges.add(.init(serverId: serverId, itemId: playlistId, change: .addToPlaylist(playlistId: playlistId, songIds: songIds), madeAt: Date()))
            return
        }
        try await source.addToPlaylist(id: playlistId, songIds: songIds)
    }

    /// Sends the changes made offline, oldest first. Stops at the first that can't reach the
    /// server (it is tried again next time); drops one the server refuses for good (the song or
    /// playlist is gone), so it can't block the rest.
    func flushPendingChanges() async {
        guard hasLoaded, !isOffline else { return }
        var done: [PendingChanges.Entry] = []
        let entries = pendingChanges.all
        // Servers that take them in one request: what they took, or the network failure that
        // keeps them for later, either way not sent one by one below.
        var batched: Set<UUID> = []
        for serverId in Set(entries.map(\.serverId)) {
            guard let source = sources[serverId] as? any BatchedOfflineEdits else { continue }
            let edits = entries.filter { $0.serverId == serverId }.compactMap { entry in entry.edit.map { (entry, $0) } }
            guard !edits.isEmpty else { continue }
            do {
                try await source.push(edits.map(\.1))
                done += edits.map(\.0)
                batched.insert(serverId)
            } catch SourceError.network, SourceError.offline {
                batched.insert(serverId)
            } catch {
                // Signed in the old way, or the request was refused: one at a time instead.
            }
        }
        for entry in entries {
            if batched.contains(entry.serverId), entry.edit != nil { continue }
            guard let source = sources[entry.serverId] else {
                // The server was removed; there's nowhere to send it.
                if !servers.contains(where: { $0.id == entry.serverId }) { done.append(entry) }
                continue
            }
            do {
                switch entry.change {
                case .favorite(let kind, let isFavorite):
                    try await source.setFavorite(FavoriteKind(storedName: kind), id: entry.itemId, isFavorite)
                case .rating(let value), .rated(_, let value):
                    try await source.setRating(id: entry.itemId, rating: value)
                case .addToPlaylist(let playlistId, let songIds):
                    try await source.addToPlaylist(id: playlistId, songIds: songIds)
                }
                done.append(entry)
            } catch SourceError.network, SourceError.offline {
                break
            } catch {
                done.append(entry)
            }
        }
        pendingChanges.remove(done)
    }

    // MARK: - Lyrics

    func lyrics(for track: Track) async throws -> [Lyrics] {
        guard let (source, songId) = await resolve(track.id) else { return [] }
        return try await source.lyrics(for: Song(id: songId, title: track.title, album: track.album, artist: track.artist))
    }

    // MARK: - Instant mix

    /// Plays songs like the given song, album or artist, picked by the server.
    func playInstantMix(itemId: String) {
        guard let source = activeSource else { return }
        perform {
            let songs = try await source.instantMix(itemId: itemId)
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

    private var sourceEnvironment: SourceEnvironment {
        SourceEnvironment(
            urlSession: Self.session, cache: responseCache, offline: offlineSwitch, clientInfo: Self.clientInfo,
            ownAudioSessions: ownAudioSessions
        )
    }

    private func rebuildClients() async {
        let environment = sourceEnvironment
        sources = Dictionary(uniqueKeysWithValues: servers.map {
            ($0.id, $0.makeSource(environment, address: activeAddresses[$0.id]))
        })
        await registry.set(sources)
        followLibraryChanges()
    }

    // MARK: - Connections

    enum ConnectionState: Equatable {
        case checking
        case connected(URL)
        case unreachable
    }

    /// The address each server is reached at right now, where it isn't the one it was added with.
    private(set) var activeAddresses: [UUID: URL] = [:]
    private(set) var connectionStates: [UUID: ConnectionState] = [:]
    private var choosing: Task<Void, Never>?

    /// For racing addresses: a wrong one must not hold the right one up.
    private static let raceSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 4
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// Picks each server's address for the network the phone is on now: the fixed one where
    /// the listener chose one, otherwise every known address tried at once, the fastest that
    /// answers as the same server kept, and remembered for this network so the next start is
    /// instant. Runs at launch, after every network change and after a request fails to reach
    /// the server. Overlapping calls join the one running.
    func chooseAddresses() async {
        if let choosing { return await choosing.value }
        let task = Task { await performChooseAddresses() }
        choosing = task
        await task.value
        choosing = nil
    }

    private func performChooseAddresses() async {
        guard !isOffline else { return }
        let network = network.signature
        var changed = false
        for record in servers {
            if case .fixed(let url) = record.connection {
                changed = changed || activeAddresses[record.id] != url
                activeAddresses[record.id] = url
                connectionStates[record.id] = .connected(url)
                continue
            }
            let candidates = record.candidateAddresses.map(\.url)
            guard candidates.count > 1 || record.serverId != nil else {
                connectionStates[record.id] = .connected(record.host)
                continue
            }
            // What worked on this network before goes first: used at once, then checked.
            let rememberedKey = "address.\(record.id.uuidString).\(network)"
            if let remembered = UserDefaults.standard.string(forKey: rememberedKey).flatMap(URL.init(string:)),
               candidates.contains(remembered), activeAddresses[record.id] != remembered {
                activeAddresses[record.id] = remembered
                changed = true
            }
            if connectionStates[record.id] == nil { connectionStates[record.id] = .checking }
            guard let won = await ServerSetup.race(record, candidates: candidates, expectedId: record.serverId, urlSession: Self.raceSession) else {
                connectionStates[record.id] = .unreachable
                continue
            }
            UserDefaults.standard.set(won.url.absoluteString, forKey: rememberedKey)
            connectionStates[record.id] = .connected(won.url)
            if activeAddresses[record.id] != won.url {
                activeAddresses[record.id] = won.url
                changed = true
            }
            // Keep up with addresses the server names (a new VPN, a changed home address).
            var updated = record
            updated.learn(won.addresses)
            // A server reinstalled from scratch (or the demo after its nightly reset) has a new id.
            if let id = won.serverId, record.kind != .subsonic { updated.serverId = id }
            if updated != record { try? await update(updated) }
        }
        if changed { await rebuildClients() }
    }

    /// Saves a changed server (addresses, connection mode) and uses it at once.
    func update(_ record: ServerRecord, signIn: Bool = false) async throws {
        let record = try await store.update(record, signIn: signIn)
        if let index = servers.firstIndex(where: { $0.id == record.id }) { servers[index] = record }
        if case .fixed(let url) = record.connection {
            activeAddresses[record.id] = url
        } else if let active = activeAddresses[record.id], !record.candidateAddresses.contains(where: { $0.url == active }) {
            activeAddresses[record.id] = nil
        }
        await rebuildClients()
    }
}

// MARK: - Catalogue

extension AppModel {
    /// own.audio's answers outside the library on the phone don't say what is a favorite; the
    /// change feed does, and the source takes it from here — with each record's kind and
    /// image link, which its covers are drawn from.
    private func noteListenerState(_ id: UUID, _ catalogue: Catalogue) {
        if let feed = catalogue.snapshot.feed {
            ownAudioSessions.listener(for: id).update(from: feed)
            ownAudioSessions.records(for: id).update(from: feed)
        }
    }

    private func loadCatalogues() async {
        let store = catalogueStore
        for record in servers {
            let id = record.id
            if let catalogue = await Task.detached(operation: { store.load(serverId: id).map(Catalogue.init) }).value {
                catalogues[id] = catalogue
                noteListenerState(id, catalogue)
            }
        }
    }

    /// Fetches each server's library where it is missing or old: the active server first. A
    /// refresh waits for a network that isn't mobile data; a first sync doesn't. Never in Low
    /// Data Mode, unless the listener asks (`force`).
    func syncCatalogues(force: Bool = false) async {
        guard hasLoaded, !isOffline, force || !network.isConstrained else { return }
        let ordered = servers.sorted { a, _ in a.id == activeServerId }
        for record in ordered {
            let id = record.id
            if !force, let existing = catalogues[id] {
                // From a change feed a refresh is only what changed: worth asking for often,
                // and small enough for mobile data.
                let fed = existing.snapshot.feed != nil
                let maxAge = fed ? Self.fedCatalogueMaxAge : Self.catalogueMaxAge
                if Date().timeIntervalSince(existing.snapshot.syncedAt) < maxAge { continue }
                if network.isExpensive, !fed { continue }
            }
            await syncCatalogue(id)
        }
    }

    /// Brings one server's library up to date now. Asked while it is already syncing, it runs
    /// once more afterwards, so a change that arrived during the sync isn't missed.
    private func syncCatalogue(_ id: UUID) async {
        guard !syncingCatalogues.contains(id) else {
            resyncRequested.insert(id)
            return
        }
        repeat {
            guard let source = sources[id] else { return }
            resyncRequested.remove(id)
            syncingCatalogues.insert(id)
            catalogueErrors[id] = nil
            do {
                let snapshot = try await Catalogue.fetch(from: source, previous: catalogues[id]?.snapshot)
                let store = catalogueStore
                let catalogue = try await Task.detached {
                    try store.save(snapshot, serverId: id)
                    return Catalogue(snapshot)
                }.value
                // The server may have been removed while its library was on the way.
                if servers.contains(where: { $0.id == id }) {
                    catalogues[id] = catalogue
                    noteListenerState(id, catalogue)
                }
            } catch {
                catalogueErrors[id] = error.userMessage
                if case SourceError.signInRejected = error { signInRefused.insert(id) }
            }
            syncingCatalogues.remove(id)
        } while resyncRequested.contains(id) && !isOffline
    }

    // MARK: - Live updates

    /// While the app is on screen and online, the active server — where it can — says when its
    /// library changes, and the copy on the phone catches up at once instead of at the next
    /// scheduled sync. A changed favorite on another device shows here within seconds.
    func sceneBecame(active: Bool) {
        engine.isInBackground = !active
        guard isInForeground != active else { return }
        isInForeground = active
        if !active {
            saveLastQueue()
            BackgroundRefresh.schedule()
            Task { await refreshWidget() }
        }
        followLibraryChanges()
        // Back on screen after a while: what changed meanwhile. Before the first load, the load
        // itself syncs.
        if active, hasLoaded {
            Task {
                if addressesNeedChoosing {
                    addressesNeedChoosing = false
                    await chooseAddresses()
                }
                await syncCatalogues()
            }
        }
    }

    /// (Re)starts or stops following the active server; called whenever what it depends on
    /// changes. The stream ends with the connection, so it is reopened, waiting longer after
    /// each failure.
    private func followLibraryChanges() {
        liveUpdates?.cancel()
        liveUpdates = nil
        guard hasLoaded, isInForeground, !isOffline, !network.isConstrained,
              let id = activeServerId, let source = sources[id] as? any LiveLibraryUpdates,
              case .ownAudio(_, _, .some) = servers.first(where: { $0.id == id })?.auth
        else { return }
        liveUpdates = Task { [weak self] in
            var wait: Duration = .seconds(2)
            while !Task.isCancelled {
                do {
                    for try await _ in source.libraryChanges() {
                        wait = .seconds(2)
                        await self?.syncCatalogue(id)
                    }
                } catch SourceError.signInRejected {
                    self?.signInRefused.insert(id)
                    return
                } catch {}
                try? await Task.sleep(for: wait)
                wait = min(wait * 2, .seconds(120))
            }
        }
    }

    var activeCatalogue: Catalogue? { activeServerId.flatMap { catalogues[$0] } }
}

enum AddServerError: LocalizedError {
    case invalidAddress, rejected, unreachable, notOwnAudio, providerOff
    /// Signing in again reached a different server than the one saved.
    case differentServer
    /// Not a failure: the code is being asked for (`AppModel.pendingTwoFactor`).
    case twoFactorNeeded
    case wrongCode

    var errorDescription: String? {
        switch self {
        case .invalidAddress: String(localized: "That doesn't look like a server address.")
        case .rejected: String(localized: "The server didn't accept that username and password.")
        case .unreachable: String(localized: "Couldn't reach the server. Check the address, and that this phone can reach it.")
        case .notOwnAudio: String(localized: "This isn't an own.audio server. Sign in with Apple or Google works only there; use the server's username and password.")
        case .providerOff: String(localized: "This own.audio server doesn't offer that sign-in. Use your email and password, or the other button.")
        case .twoFactorNeeded: String(localized: "Enter the code from your authenticator app.")
        case .wrongCode: String(localized: "That code isn't right, or it has expired. Try the current one.")
        case .differentServer: String(localized: "That address now answers as a different server. Add it as a new server instead.")
        }
    }
}

extension Error {
    /// A short sentence for a failed request.
    var userMessage: String {
        // Every failure a screen shows passes through here, so this is where it is logged.
        Logger.app.error("shown to the listener: \(String(describing: self), privacy: .public)")
        guard let error = self as? SourceError else {
            return String(localized: "Something went wrong.")
        }
        switch error {
        case .signInRejected:
            return String(localized: "The server no longer accepts this sign-in. Check it in Settings.")
        case .notAllowed:
            return String(localized: "This account isn't allowed to do that.")
        case .notFound:
            return String(localized: "The server doesn't have that any more.")
        case .http(let code):
            return String(localized: "The server returned an error (\(code)).")
        case .server(let message):
            return message
        case .unreadable:
            return String(localized: "The server's answer couldn't be read.")
        case .network:
            return String(localized: "Couldn't reach the server.")
        case .offline:
            return String(localized: "Not available offline.")
        case .unsupported:
            return String(localized: "This server doesn't support that.")
        }
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

extension Logger {
    /// What went wrong in the app; read with Console or `log stream`, and kept by the UI tests.
    static let app = Logger(subsystem: "audio.own.musicplayer", category: "app")
    static let network = Logger(subsystem: "audio.own.musicplayer", category: "network")
}

// MARK: - The last queue, back after a relaunch

/// The queue in the player when the app went away: shown in the mini player at its track and
/// position, and loaded only when played, as in the books app. Stop and the end of the queue
/// clear it.
struct LastQueue: Codable, Equatable {
    let tracks: [Track]
    let currentTrackId: String
    let positionSecs: Double

    var current: Track? { tracks.first { $0.id == currentTrackId } }

    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("last-queue.json")
    }

    static func load() -> LastQueue? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(LastQueue.self, from: $0) }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.file, options: .atomic)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: file)
    }
}

extension AppModel {
    /// Saves the queue when playback pauses, plays or moves to another track; a stop — the
    /// player letting go of its track — forgets it.
    func observeQueueForRelaunch() {
        withObservationTracking {
            _ = engine.isPlaying
            _ = engine.currentTrack?.id
        } onChange: {
            Task { @MainActor [weak self] in
                self?.queueChanged()
                self?.observeQueueForRelaunch()
            }
        }
    }

    private func queueChanged() {
        if let current = engine.currentTrack, current.id != lastSavedTrackId {
            downloads.notePlayed(current.id)
            Task { await refreshWidget() }
        }
        if engine.currentTrack != nil {
            saveLastQueue()
        } else if lastSavedTrackId != nil {
            // Something was playing and nothing is now: stopped, or the queue ran out.
            lastSavedTrackId = nil
            lastQueue = nil
            LastQueue.remove()
        }
    }

    func saveLastQueue() {
        guard let current = engine.currentTrack else { return }
        let all = engine.playedTracks + [current] + engine.upcomingTracks
        LastQueue(tracks: all, currentTrackId: current.id, positionSecs: engine.currentTime).save()
        lastSavedTrackId = current.id
        lastQueue = nil
    }

    /// Plays the last queue from where it was.
    func playLastQueue() async {
        guard let last = lastQueue else { return }
        engine.setShuffled(false)
        await engine.play(tracks: last.tracks, startTrackId: last.currentTrackId, startPositionSecs: last.positionSecs)
        lastQueue = nil
    }
}

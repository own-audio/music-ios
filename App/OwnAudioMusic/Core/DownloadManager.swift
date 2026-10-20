import Foundation
import Observation
import MusicEngine
import MusicLibrary

/// Songs kept on the phone for offline listening, and the albums and playlists they were
/// downloaded as.
///
/// Files live in Application Support, which iOS doesn't clear the way it clears Caches, and are
/// excluded from iCloud backup: they can always be downloaded again. An index file records what
/// each file is, so the Downloads screen works with no network at all.
///
/// Downloads go through a background `URLSession`, as in the books and podcasts apps: a song
/// handed to it keeps downloading with the app in the background or killed, and iOS wakes the
/// app when it is done, which hands the session the next songs. Two at a time, so the links
/// (own.audio's are signed for a while) are fresh when a song's turn comes.
@Observable
@MainActor
final class DownloadManager: NSObject {
    enum State: Equatable {
        case queued
        case downloading
        case downloaded
        case failed(String)
    }

    struct DownloadedTrack: Codable, Equatable {
        let trackId: String
        let song: Song
        let fileName: String
        let bytes: Int64
        let downloadedAt: Date
        /// When it last played; what goes first when downloads outgrow Keep at Most.
        var lastPlayedAt: Date?
    }

    /// An album or playlist downloaded as a whole, in its own order.
    struct Collection: Codable, Equatable, Identifiable {
        enum Kind: String, Codable { case album, playlist }
        let id: String
        let kind: Kind
        let serverId: UUID
        let itemId: String
        let name: String
        let artist: String?
        let coverArt: String?
        var trackIds: [String]
    }

    private struct Index: Codable {
        var tracks: [String: DownloadedTrack] = [:]
        var collections: [String: Collection] = [:]
        /// Waiting or interrupted, in order; resumed on the next launch.
        var queue: [QueuedTrack] = []
        /// Resume data of downloads that were interrupted, by track id.
        var resumeData: [String: Data]? = nil
    }

    struct QueuedTrack: Codable, Equatable {
        let trackId: String
        let song: Song
    }

    private(set) var tracks: [String: DownloadedTrack] = [:]
    private(set) var collections: [String: Collection] = [:]
    private(set) var states: [String: State] = [:]

    /// Wi-Fi only: the session waits for Wi-Fi instead of using mobile data.
    var wifiOnly = true { didSet { if wifiOnly != oldValue { restart() } } }
    /// Keep at Most, in bytes; nil is no limit.
    var capBytes: Int64? { didSet { if capBytes != oldValue { enforceCap() } } }
    /// The song playing now, never let go to make room.
    var protectedTrackId: (() -> String?)?
    /// Set when iOS relaunched the app for the session's events; called once they are handled.
    var backgroundCompletion: (() -> Void)?

    /// Read by the engine's resolver off the main actor.
    let files: LocalFileIndex
    private let directory: URL
    private let indexURL: URL
    private var queue: [QueuedTrack] = []
    /// Songs handed to the session, or having their address worked out.
    private var running: [String: URLSessionDownloadTask?] = [:]
    private var resumeData: [String: Data] = [:]
    private let registry: ClientRegistry
    private var session: URLSession!
    private static let parallelDownloads = 2
    static let sessionIdentifier = "audio.own.musicplayer.downloads"

    /// `root` is for tests: a folder of their own and an ordinary session, since a background
    /// session's identifier can be open only once in a process.
    init(registry: ClientRegistry, root: URL? = nil) {
        self.registry = registry
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("Downloads", isDirectory: true)
        indexURL = directory.appendingPathComponent("index.json")
        files = LocalFileIndex()
        super.init()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)

        let configuration: URLSessionConfiguration
        if root == nil {
            configuration = .background(withIdentifier: Self.sessionIdentifier)
            configuration.isDiscretionary = false
            configuration.sessionSendsLaunchEvents = true
        } else {
            configuration = .default
        }
        configuration.timeoutIntervalForResource = 60 * 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        loadIndex()
    }

    // MARK: - Reading

    var totalBytes: Int64 { tracks.values.reduce(0) { $0 + $1.bytes } }

    func state(of trackId: String) -> State? { states[trackId] }

    func isDownloaded(_ trackId: String) -> Bool { tracks[trackId] != nil }

    /// Downloaded songs that belong to no downloaded album or playlist.
    var looseTracks: [DownloadedTrack] {
        let inCollections = Set(collections.values.flatMap(\.trackIds))
        return tracks.values.filter { !inCollections.contains($0.trackId) }.sorted { $0.downloadedAt > $1.downloadedAt }
    }

    /// The collection's songs that are on the phone, in its order.
    func songs(in collection: Collection) -> [DownloadedTrack] {
        collection.trackIds.compactMap { tracks[$0] }
    }

    /// How far a collection has got: (downloaded, total).
    func progress(of collectionId: String) -> (done: Int, total: Int)? {
        guard let collection = collections[collectionId] else { return nil }
        return (collection.trackIds.filter { tracks[$0] != nil }.count, collection.trackIds.count)
    }

    static func collectionId(kind: Collection.Kind, serverId: UUID, itemId: String) -> String {
        "\(kind.rawValue):\(TrackID.make(serverId: serverId, itemId: itemId))"
    }

    // MARK: - Changing

    func download(songs: [Song], serverId: UUID) {
        for song in songs {
            let trackId = TrackID.make(serverId: serverId, itemId: song.id)
            guard tracks[trackId] == nil, !queue.contains(where: { $0.trackId == trackId }) else { continue }
            queue.append(QueuedTrack(trackId: trackId, song: song))
            states[trackId] = .queued
        }
        saveIndex()
        pump()
    }

    func download(album: Album, songs: [Song], serverId: UUID) {
        let id = Self.collectionId(kind: .album, serverId: serverId, itemId: album.id)
        collections[id] = Collection(
            id: id, kind: .album, serverId: serverId, itemId: album.id, name: album.name,
            artist: album.artist, coverArt: album.coverArt ?? album.id,
            trackIds: songs.map { TrackID.make(serverId: serverId, itemId: $0.id) }
        )
        download(songs: songs, serverId: serverId)
    }

    func download(playlist: Playlist, songs: [Song], serverId: UUID) {
        let id = Self.collectionId(kind: .playlist, serverId: serverId, itemId: playlist.id)
        collections[id] = Collection(
            id: id, kind: .playlist, serverId: serverId, itemId: playlist.id, name: playlist.name,
            artist: nil, coverArt: playlist.coverArt,
            trackIds: songs.map { TrackID.make(serverId: serverId, itemId: $0.id) }
        )
        download(songs: songs, serverId: serverId)
    }

    /// Removes a song's file, unless another downloaded album or playlist still needs it.
    func remove(trackId: String) {
        let stillNeeded = collections.values.contains { $0.trackIds.contains(trackId) }
        if !stillNeeded { deleteFile(trackId) }
        saveIndex()
    }

    func remove(collectionId: String) {
        guard let collection = collections.removeValue(forKey: collectionId) else { return }
        let stillNeeded = Set(collections.values.flatMap(\.trackIds))
        for trackId in collection.trackIds where !stillNeeded.contains(trackId) {
            cancel(trackId)
            deleteFile(trackId)
        }
        saveIndex()
    }

    func removeAll(serverId: UUID? = nil) {
        let doomed = tracks.keys.filter { serverId == nil || TrackID.parse($0)?.serverId == serverId }
            + queue.map(\.trackId).filter { serverId == nil || TrackID.parse($0)?.serverId == serverId }
        collections = collections.filter { serverId != nil && $0.value.serverId != serverId }
        for trackId in Set(doomed) {
            cancel(trackId)
            deleteFile(trackId)
        }
        saveIndex()
    }

    /// Tries failed downloads again.
    func retryFailed() {
        for item in queue {
            if case .failed? = states[item.trackId] { states[item.trackId] = .queued }
        }
        pump()
    }

    var failedCount: Int {
        queue.filter { if case .failed? = states[$0.trackId] { true } else { false } }.count
    }

    var pendingCount: Int {
        queue.filter { states[$0.trackId] == .queued || states[$0.trackId] == .downloading }.count
    }

    /// A downloaded song played: it moves to the back of the line for Keep at Most.
    func notePlayed(_ trackId: String) {
        guard tracks[trackId] != nil else { return }
        tracks[trackId]?.lastPlayedAt = Date()
        saveIndex()
    }

    /// Lets go of songs until the downloads fit Keep at Most: the ones not played for longest
    /// first, never the one playing. A song an album still lists goes too; the album then shows
    /// as partly downloaded.
    func enforceCap() {
        let policy = EvictionPolicy(capBytes: capBytes)
        let candidates = tracks.values.map {
            EvictionPolicy.Candidate(id: $0.trackId, bytes: $0.bytes, isFinished: false, lastUsedAt: $0.lastPlayedAt ?? $0.downloadedAt)
        }
        let evictions = policy.evictions(from: candidates, protected: protectedTrackId?())
        guard !evictions.isEmpty else { return }
        for trackId in evictions { deleteFile(trackId) }
        saveIndex()
    }

    // MARK: - Work

    private func pump() {
        let waiting = queue.filter { states[$0.trackId] == .queued && running[$0.trackId] == nil }
        let free = Self.parallelDownloads - running.count
        for item in waiting.prefix(max(free, 0)) {
            start(item)
        }
    }

    private func start(_ item: QueuedTrack) {
        states[item.trackId] = .downloading
        if let data = resumeData.removeValue(forKey: item.trackId) {
            let task = session.downloadTask(withResumeData: data)
            task.taskDescription = item.trackId
            running[item.trackId] = task
            task.resume()
            saveIndex()
            return
        }
        running[item.trackId] = .some(nil)
        Task {
            do {
                let url = try await registry.downloadURL(trackId: item.trackId)
                guard running[item.trackId] != nil, queue.contains(where: { $0.trackId == item.trackId }) else { return }
                var request = URLRequest(url: url)
                request.allowsCellularAccess = !wifiOnly
                let task = session.downloadTask(with: request)
                task.taskDescription = item.trackId
                running[item.trackId] = task
                task.resume()
            } catch {
                running[item.trackId] = nil
                guard queue.contains(where: { $0.trackId == item.trackId }) else { return }
                states[item.trackId] = .failed(error.userMessage)
                pump()
            }
        }
    }

    /// The session finished a song: the file is checked, kept, and the next song goes.
    private func finished(trackId: String, file: URL, response: URLResponse?) {
        running[trackId] = nil
        defer { pump() }
        guard let item = queue.first(where: { $0.trackId == trackId }) else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        do {
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let head = (try? FileHandle(forReadingFrom: file)).flatMap { handle in
                defer { try? handle.close() }
                return try? handle.read(upToCount: 12)
            } ?? Data()
            // Subsonic reports errors as HTTP 200 with JSON; that must not be saved as a song.
            guard let ext = TrackFileCache.fileExtension(prefix: head)
                    ?? TrackFileCache.fileExtension(mimeType: http.mimeType) else {
                throw URLError(.cannotDecodeContentData)
            }
            let fileName = "\(Self.safeName(trackId)).\(ext)"
            let destination = directory.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: file, to: destination)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0

            tracks[trackId] = DownloadedTrack(trackId: trackId, song: item.song, fileName: fileName, bytes: bytes, downloadedAt: Date())
            files.set(trackId, destination)
            states[trackId] = .downloaded
            queue.removeAll { $0.trackId == trackId }
            saveIndex()
            enforceCap()
        } catch {
            try? FileManager.default.removeItem(at: file)
            states[trackId] = .failed(error.userMessage)
        }
    }

    private func failed(trackId: String, error: Error, resume: Data?) {
        running[trackId] = nil
        if let resume { resumeData[trackId] = resume }
        if (error as NSError).code != NSURLErrorCancelled, queue.contains(where: { $0.trackId == trackId }) {
            states[trackId] = .failed(error.userMessage)
        }
        saveIndex()
        pump()
    }

    /// Wi-Fi Only changed: what is under way starts again under the new rule, from where it got.
    private func restart() {
        for (trackId, task) in running {
            guard let task else { continue }
            running[trackId] = nil
            task.cancel { [weak self] data in
                Task { @MainActor in
                    guard let self, let item = self.queue.first(where: { $0.trackId == trackId }) else { return }
                    if let data { self.resumeData[trackId] = data }
                    self.start(item)
                }
            }
        }
    }

    private func cancel(_ trackId: String) {
        if let task = running.removeValue(forKey: trackId) { task?.cancel() }
        resumeData[trackId] = nil
        queue.removeAll { $0.trackId == trackId }
        states[trackId] = nil
    }

    private func deleteFile(_ trackId: String) {
        cancel(trackId)
        if let track = tracks.removeValue(forKey: trackId) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(track.fileName))
        }
        files.set(trackId, nil)
        states[trackId] = nil
    }

    // MARK: - Index

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(Index.self, from: data)
        else { return }
        // A file the index lists but the disk lost (restored backup, manual cleanup) isn't
        // downloaded any more.
        tracks = index.tracks.filter {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.value.fileName).path)
        }
        collections = index.collections
        queue = index.queue
        resumeData = index.resumeData ?? [:]
        for track in tracks.values {
            states[track.trackId] = .downloaded
            files.set(track.trackId, directory.appendingPathComponent(track.fileName))
        }
        for item in queue { states[item.trackId] = .queued }
        if tracks.count != index.tracks.count { saveIndex() }
    }

    /// Picks up what the session still has (it went on while the app was gone), then starts
    /// what was waiting.
    func resume() {
        session.getAllTasks { [weak self] tasks in
            let found = (tasks as? [URLSessionDownloadTask] ?? []).compactMap { task in
                task.taskDescription.map { ($0, task) }
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for (trackId, task) in found where self.running[trackId] == nil {
                    if self.queue.contains(where: { $0.trackId == trackId }) {
                        self.running[trackId] = task
                        self.states[trackId] = .downloading
                    } else {
                        task.cancel()
                    }
                }
                self.pump()
            }
        }
    }

    private func saveIndex() {
        let index = Index(tracks: tracks, collections: collections, queue: queue, resumeData: resumeData.isEmpty ? nil : resumeData)
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private static func safeName(_ trackId: String) -> String {
        Data(trackId.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    /// The file must be moved before this returns; it is moved here, on the session's queue,
    /// and checked on the main actor afterwards.
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let trackId = downloadTask.taskDescription ?? ""
        let response = downloadTask.response
        let holding = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.moveItem(at: location, to: holding)
        Task { @MainActor in self.finished(trackId: trackId, file: holding, response: response) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let trackId = task.taskDescription ?? ""
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor in self.failed(trackId: trackId, error: error, resume: resume) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }
}

/// Track id → local file, readable from any thread: the engine asks from its own tasks.
final class LocalFileIndex: @unchecked Sendable {
    private var files: [String: URL] = [:]
    private let lock = NSLock()

    func set(_ trackId: String, _ url: URL?) {
        lock.lock()
        defer { lock.unlock() }
        files[trackId] = url
    }

    func url(for trackId: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return files[trackId]
    }
}

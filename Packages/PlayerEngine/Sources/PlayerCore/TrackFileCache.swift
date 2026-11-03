import Foundation

/// Finds audio for a track id: a downloaded copy if there is one, otherwise the remote URL to
/// stream from, or a full download into a temporary cache.
///
/// `AVAudioFile` only reads local files, so gapless scheduling of the *next* track needs it
/// complete on disk; the current track can stream (`stream`). The temporary cache is separate
/// from the listener's own downloads: a track played once shouldn't count as downloaded.
public actor TrackFileCache {
    /// The remote URL for a track id. Supplied by the app, which knows which server a track
    /// belongs to; the engine doesn't.
    public typealias RemoteURLResolver = @Sendable (String) async throws -> URL
    /// A permanently downloaded copy, if any.
    public typealias LocalFileLookup = @Sendable (String) async -> URL?

    private let remoteURL: RemoteURLResolver
    private var localFile: LocalFileLookup?
    private let session: URLSession
    /// Whether a smaller copy the server made (Saver on mobile data) counts as the track. Off,
    /// only the original does: a transcode kept from the train is not what Wi-Fi should play.
    private var acceptsReducedCopies = false
    /// So a quick next/previous during a download doesn't start a second one.
    private var inFlight: [String: Task<URL, Error>] = [:]
    private let cacheDirectory: URL
    /// Where own.audio storage is blocked, its files come through the server's media proxy.
    public nonisolated let storageRoute: ProxyMemory?

    public init(remoteURL: @escaping RemoteURLResolver, session: URLSession = .shared, cacheDirectory: URL? = nil, storageRoute: ProxyMemory? = nil) {
        self.remoteURL = remoteURL
        self.session = session
        self.storageRoute = storageRoute
        self.cacheDirectory = cacheDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("player-engine-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
    }

    public func setLocalFileLookup(_ lookup: @escaping LocalFileLookup) {
        localFile = lookup
    }

    /// Whether the player is on a smaller stream now (Saver on mobile data), so a smaller copy
    /// already here will do. The app sets it with the stream quality.
    public func setAcceptsReducedCopies(_ accepts: Bool) {
        acceptsReducedCopies = accepts
    }

    /// Whether `url` is a smaller stream the server makes rather than the original: an own.audio
    /// link for a transcode (`f=aac`, `f=mp3`), a Subsonic `stream` with `maxBitRate` or a
    /// `format`, a Jellyfin stream that is not `static`. What arrives from one is cached as a
    /// reduced copy, kept apart from the original.
    public nonisolated static func isReducedStream(_ url: URL) -> Bool {
        guard !url.isFileURL, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        func value(_ name: String) -> String? {
            items.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        if url.path.hasSuffix("/api/v2/stream") {
            return value("f").map { $0.lowercased() != "orig" } ?? false
        }
        if let rate = value("maxBitRate") ?? value("audioBitRate") ?? value("maxStreamingBitrate"), (Int(rate) ?? 0) > 0 {
            return true
        }
        if let format = value("format"), !["", "raw"].contains(format.lowercased()) { return true }
        return value("static")?.lowercased() == "false"
    }

    public func resolveRemoteURL(trackId: String) async throws -> URL {
        try await remoteURL(trackId)
    }

    /// The session downloads go through, for engines that stream with the same one.
    public nonisolated var urlSession: URLSession { session }

    /// A local file if one already exists, without starting a download; that is the decision
    /// between streaming and playing from disk.
    public func existingLocalURL(trackId: String) async -> URL? {
        if let downloaded = await localFile?(trackId) { return downloaded }
        return existingCachedFile(trackId: trackId)
    }

    /// A local file for `trackId`, downloading it into the cache first if needed.
    public func localURL(trackId: String) async throws -> URL {
        if let existing = await existingLocalURL(trackId: trackId) { return existing }
        if let task = inFlight[trackId] { return try await task.value }

        let task = Task { try await download(trackId: trackId) }
        inFlight[trackId] = task
        defer { inFlight[trackId] = nil }
        return try await task.value
    }

    /// Starts or joins a download without waiting for it.
    public func prefetch(trackId: String) {
        guard inFlight[trackId] == nil, existingCachedFile(trackId: trackId) == nil else { return }
        Task { _ = try? await localURL(trackId: trackId) }
    }

    /// Empties the temporary cache, e.g. when a server is removed.
    public func clear() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    private func cacheFileName(trackId: String) -> String {
        // Ids are opaque and may contain characters a file name can't.
        Data(trackId.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
    }

    /// A reduced copy is named apart from the original (`<id>~reduced.aac`).
    private static let reducedSuffix = "~reduced"

    private func existingCachedFile(trackId: String) -> URL? {
        let name = cacheFileName(trackId: trackId)
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? []
        let stems = files.filter { $0.pathExtension != "part" }.map { ($0, $0.deletingPathExtension().lastPathComponent) }
        if let original = stems.first(where: { $0.1 == name })?.0 { return original }
        guard acceptsReducedCopies else { return nil }
        return stems.first { $0.1 == name + Self.reducedSuffix }?.0
    }

    private func cachedDestination(trackId: String, ext: String, reduced: Bool) -> URL {
        cacheDirectory.appendingPathComponent("\(cacheFileName(trackId: trackId))\(reduced ? Self.reducedSuffix : "").\(ext)")
    }

    /// Puts `file` in the cache as the track, or as its reduced copy. The original replaces a
    /// reduced copy; a reduced copy never replaces the original.
    private func keep(_ file: URL, trackId: String, ext: String, reduced: Bool) throws -> URL {
        let destination = cachedDestination(trackId: trackId, ext: ext, reduced: reduced)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: file, to: destination)
        if !reduced {
            let name = cacheFileName(trackId: trackId) + Self.reducedSuffix
            for old in (try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? []
            where old.deletingPathExtension().lastPathComponent == name {
                try? FileManager.default.removeItem(at: old)
            }
        }
        return destination
    }

    // MARK: - A stream kept as it passes

    /// A fresh, empty file the streaming source writes into as the bytes arrive. Not a cached
    /// track until `commitPartial`; `existingLocalURL` never returns it.
    public func partialURL(trackId: String) -> URL {
        let url = cacheDirectory.appendingPathComponent("\(cacheFileName(trackId: trackId)).part")
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    /// The stream arrived whole: the partial file becomes the cached track, named by what the
    /// bytes say it is, as a download would be — or its reduced copy, when the stream was one.
    public func commitPartial(trackId: String, mimeType: String?, reduced: Bool = false) {
        let partial = cacheDirectory.appendingPathComponent("\(cacheFileName(trackId: trackId)).part")
        guard FileManager.default.fileExists(atPath: partial.path) else { return }
        let head = (try? FileHandle(forReadingFrom: partial)).flatMap { handle in
            defer { try? handle.close() }
            return try? handle.read(upToCount: 12)
        } ?? Data()
        guard AudioPayloadCheck.looksLikeAudio(contentType: mimeType, prefix: head) else {
            try? FileManager.default.removeItem(at: partial)
            return
        }
        let ext = Self.fileExtension(prefix: head) ?? Self.fileExtension(mimeType: mimeType) ?? "audio"
        _ = try? keep(partial, trackId: trackId, ext: ext, reduced: reduced)
    }

    public func discardPartial(trackId: String) {
        try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent("\(cacheFileName(trackId: trackId)).part"))
    }

    private func download(trackId: String) async throws -> URL {
        let url = try await remoteURL(trackId)
        let session = session
        let tempURL: URL, response: URLResponse
        if let storageRoute {
            (tempURL, response) = try await storageRoute.fetch(url) { try await session.download(from: $0) }
        } else {
            (tempURL, response) = try await session.download(from: url)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw PlaybackError.network("Could not download track \(trackId)")
        }
        // Subsonic servers report errors as HTTP 200 with a JSON body.
        guard AudioPayloadCheck.looksLikeAudio(contentType: http.mimeType, fileURL: tempURL) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw PlaybackError.network("Server sent an error instead of track \(trackId)")
        }
        // AVAudioFile picks its parser partly by extension, and Subsonic stream URLs end in
        // `stream.view`. The file's own magic bytes win over the content type, which servers
        // get wrong.
        let head = (try? FileHandle(forReadingFrom: tempURL)).flatMap { handle in
            defer { try? handle.close() }
            return try? handle.read(upToCount: 12)
        } ?? Data()
        let ext = Self.fileExtension(prefix: head) ?? Self.fileExtension(mimeType: http.mimeType) ?? "audio"
        return try keep(tempURL, trackId: trackId, ext: ext, reduced: Self.isReducedStream(url))
    }

    public static func fileExtension(prefix: Data) -> String? {
        let bytes = Array(prefix.prefix(12))
        func starts(_ text: String, at offset: Int = 0) -> Bool {
            let magic = Array(text.utf8)
            return bytes.count >= offset + magic.count && Array(bytes[offset..<offset + magic.count]) == magic
        }
        if starts("ftyp", at: 4) { return "m4a" }
        if starts("fLaC") { return "flac" }
        if starts("OggS") { return "ogg" }
        if starts("RIFF") { return "wav" }
        if starts("FORM") { return "aiff" }
        // ADTS AAC (a server's transcode on mobile data) shares MP3's frame sync; its layer bits
        // are 00, which no MP3 frame has. Saved as .mp3 it would not open at all.
        if bytes.count >= 2 && bytes[0] == 0xFF && (bytes[1] & 0xF6) == 0xF0 { return "aac" }
        if starts("ID3") || (bytes.count >= 2 && bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0) { return "mp3" }
        return nil
    }

    public static func fileExtension(mimeType: String?) -> String? {
        switch mimeType?.lowercased() {
        case "audio/mpeg", "audio/mp3": "mp3"
        case "audio/flac", "audio/x-flac": "flac"
        case "audio/mp4", "audio/m4a", "audio/x-m4a": "m4a"
        case "audio/aac", "audio/aacp": "aac"
        case "audio/ogg", "audio/opus": "ogg"
        case "audio/wav", "audio/x-wav", "audio/wave": "wav"
        case "audio/aiff", "audio/x-aiff": "aiff"
        default: nil
        }
    }
}

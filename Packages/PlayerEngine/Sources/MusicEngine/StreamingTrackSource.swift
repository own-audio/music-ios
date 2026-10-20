import AVFoundation
import AudioToolbox
import Foundation
import OSLog

/// Streams one track from its URL, decoding it progressively via `AudioStreamDecoder`
/// and handing PCM buffers to a caller as they become available — the piece that lets
/// `PlaybackEngine` start playing before a track has fully downloaded.
///
/// Deliberately split from `AudioStreamDecoder`: that type is pure Core Audio with no networking
/// (and is unit tested that way, against real audio bytes with no HTTP anywhere near the test);
/// this type is pure networking plumbing around it.
///
/// The download and the decoding run apart. The download goes into the cache's partial file as
/// fast as the network allows; the decoder reads that file at the player's pace, waiting when
/// it catches up. They used to be one loop, so the player's look-ahead (two minutes decoded,
/// then wait) stopped the reading too: the connection sat idle, the request timed out after
/// 15 s, and a FLAC on a fast server ended about 30 s in.
public actor StreamingTrackSource {
    /// Thrown instead of a decode error specifically for `AudioStreamDecoder.DecoderError
    /// .streamParseFailed` carrying `kAudioFileStreamError_NotOptimized` — an M4A/ALAC file
    /// whose `moov` atom trails the audio data, which Core Audio's stream parser refuses to
    /// parse progressively no matter how it arrives (see `AudioStreamDecoderTests`). The caller should not treat this as a playback failure —
    /// it should fetch `localURL` (a full download through the existing `TrackFileCache`,
    /// the same path a downloaded track already takes) and play that via `AVAudioFile` instead.
    public struct FallbackToLocalPlaybackRequired: Error, Sendable {
        public let localURL: URL
    }

    private let fileCache: TrackFileCache
    private let session: URLSession
    private let decoder = AudioStreamDecoder()

    /// Bytes are batched to this size before being handed to `AudioStreamDecoder.ingest(_:)` —
    /// large enough that decoding isn't dominated by per-call overhead, small enough that "first
    /// sound" latency isn't held hostage to an oversized first read. iOS's own default TCP
    /// receive-buffer growth means real reads from `URLSession.bytes` arrive in chunks close to
    /// this size anyway.
    private static let ingestChunkSize = 16 * 1024
    /// What the download hands on at a time: no more than the decoder takes, or a slow
    /// network would hold back sound that has arrived.
    private static let downloadChunkSize = ingestChunkSize

    /// How much may go into the decoder with no audio coming out before it is given up for the
    /// whole file: a few seconds of even the richest FLAC, far more than any header.
    static let silentDecoderLimit = 512 * 1024

    private var bytesIngested = 0
    private var framesDecoded: AVAudioFramePosition = 0

    public init(fileCache: TrackFileCache, session: URLSession = .shared) {
        self.fileCache = fileCache
        self.session = session
    }

    /// Streams `trackId`, calling `onBuffer` for every decoded chunk in order as it becomes
    /// available, and returning once the stream is exhausted. Throws
    /// `FallbackToLocalPlaybackRequired` for the ALAC trailing-`moov` case (see that type's own
    /// doc comment) — every other thrown error is a genuine playback failure.
    public func stream(
        trackId: String,
        onBuffer: @Sendable (AudioStreamDecoder.DecodedBuffer) async -> Void,
        /// Fired once, the first time the decoder's format becomes readable — the source of a
        /// "FLAC · 44.1 kHz · 16-bit" badge for a streamed track.
        onFormatKnown: @Sendable (AudioStreamDecoder.FormatInfo) async -> Void = { _ in }
    ) async throws {
        let remoteURL = try await fileCache.resolveRemoteURL(trackId: trackId)
        let (byteStream, response) = try await session.bytes(from: remoteURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PlaybackError.network("Could not stream track \(trackId) (status \((response as? HTTPURLResponse)?.statusCode ?? -1))")
        }

        // Every byte goes to the cache's partial file, so a seek within the track or a second
        // listen comes from disk, and the decoder reads it back from there. Without a file
        // (a full disk) the bytes wait in memory instead.
        let partialURL = await fileCache.partialURL(trackId: trackId)
        let writer = try? FileHandle(forWritingTo: partialURL)
        let reader = writer == nil ? nil : try? FileHandle(forReadingFrom: partialURL)
        let relay = DownloadRelay(writer: reader == nil ? nil : writer)
        if reader == nil { try? writer?.close() }
        let fileCache = fileCache
        let mimeType = http.mimeType
        let download = Task {
            do {
                var chunk = Data()
                chunk.reserveCapacity(Self.downloadChunkSize)
                for try await byte in byteStream {
                    chunk.append(byte)
                    if chunk.count >= Self.downloadChunkSize {
                        try await relay.append(chunk)
                        chunk.removeAll(keepingCapacity: true)
                    }
                }
                if !chunk.isEmpty { try await relay.append(chunk) }
                // Whole: it becomes the cached track now, whatever the decoder is doing. The
                // reader's open handle goes on reading the same file under its new name.
                if await relay.closeFile() {
                    await fileCache.commitPartial(trackId: trackId, mimeType: mimeType)
                }
                await relay.finish(nil)
            } catch {
                await relay.finish(error)
            }
        }
        defer { try? reader?.close() }

        var pending = Data()
        pending.reserveCapacity(Self.ingestChunkSize)
        var formatReported = false
        // Checked once, on the first chunk: a Subsonic error body arrives with a 200 (see
        // `AudioPayloadCheck`), and handing it to the decoder produces an opaque parse failure
        // rather than naming what actually went wrong.
        var payloadChecked = false

        do {
            var offset = 0
            while let data = try await withTaskCancellationHandler(operation: {
                try await relay.next(after: offset, reader: reader, max: Self.ingestChunkSize)
            }, onCancel: {
                Task { await relay.finish(CancellationError()) }
            }) {
                offset += data.count
                pending.append(data)
                if !payloadChecked, pending.count >= 64 {
                    payloadChecked = true
                    guard AudioPayloadCheck.looksLikeAudio(contentType: http.mimeType, prefix: pending) else {
                        throw PlaybackError.network("Server sent an error instead of track \(trackId)")
                    }
                }
                if pending.count >= Self.ingestChunkSize {
                    try await ingestAndDrain(pending, onBuffer: onBuffer, formatReported: &formatReported, onFormatKnown: onFormatKnown)
                    pending.removeAll(keepingCapacity: true)
                }
            }
            if !pending.isEmpty {
                try await ingestAndDrain(pending, onBuffer: onBuffer, formatReported: &formatReported, onFormatKnown: onFormatKnown)
            }
            try await decoder.finish()
            while let decoded = try await decoder.nextBuffer() {
                if !formatReported, let format = await decoder.currentFormatInfo() {
                    formatReported = true
                    await onFormatKnown(format)
                }
                framesDecoded += AVAudioFramePosition(decoded.buffer.frameLength)
                await onBuffer(decoded)
            }
            if framesDecoded == 0 { throw AudioStreamDecoder.DecoderError.producedNothing }
        } catch let error as AudioStreamDecoder.DecoderError {
            Logger.playback.error("decoding \(trackId, privacy: .public) in pieces failed (\(String(describing: error), privacy: .public)); playing the whole file instead")
            // *Any* decoding failure falls back to the file, not only the one known
            // trailing-`moov` case this started as. A track in this library reproduced the
            // point exactly: a perfectly ordinary 44.1 kHz/16-bit FLAC that `AVAudioFile` reads
            // end to end, and that progressive decoding rejects with `'bada'` on its very first
            // chunk. Whatever the decoder cannot take in pieces, it can still take whole, and
            // "could not play this track" was a lie about the music rather than about us.
            // The download is under way already; it finishes into the cache first.
            await download.value
            guard let localURL = try? await fileCache.localURL(trackId: trackId) else { throw error }
            throw FallbackToLocalPlaybackRequired(localURL: localURL)
        } catch {
            // Cancelled or broken off: half a file must not pass for the track. One that
            // already arrived whole stays cached.
            download.cancel()
            await download.value
            await fileCache.discardPartial(trackId: trackId)
            throw error
        }
    }

    /// The engine's own format read-out, once streaming has produced at least one buffer —
    /// `nil` before that point, same as `AudioStreamDecoder.currentFormatInfo()` itself.
    public func currentFormatInfo() async -> AudioStreamDecoder.FormatInfo? {
        await decoder.currentFormatInfo()
    }

    private func ingestAndDrain(
        _ chunk: Data, onBuffer: @Sendable (AudioStreamDecoder.DecodedBuffer) async -> Void,
        formatReported: inout Bool, onFormatKnown: @Sendable (AudioStreamDecoder.FormatInfo) async -> Void
    ) async throws {
        try await decoder.ingest(chunk)
        bytesIngested += chunk.count
        while let decoded = try await decoder.nextBuffer() {
            if !formatReported, let format = await decoder.currentFormatInfo() {
                formatReported = true
                await onFormatKnown(format)
            }
            framesDecoded += AVAudioFramePosition(decoded.buffer.frameLength)
            await onBuffer(decoded)
        }
        if framesDecoded == 0, bytesIngested >= Self.silentDecoderLimit {
            throw AudioStreamDecoder.DecoderError.producedNothing
        }
    }
}

extension TrackFileCache {
    /// Streams `trackId` progressively. Throws `StreamingTrackSource.FallbackToLocalPlaybackRequired`
    /// for audio that can't be decoded in pieces; the caller then plays the full file instead.
    public func stream(
        trackId: String, onBuffer: @Sendable (AudioStreamDecoder.DecodedBuffer) async -> Void,
        onFormatKnown: @Sendable (AudioStreamDecoder.FormatInfo) async -> Void = { _ in }
    ) async throws {
        // A fresh source per track: it carries decoder state that must not leak into the next.
        let source = StreamingTrackSource(fileCache: self, session: urlSession)
        try await source.stream(trackId: trackId, onBuffer: onBuffer, onFormatKnown: onFormatKnown)
    }
}

/// Hands the download to the decoder: the downloader appends, to the partial file or, without
/// one, to memory; the decoder waits for bytes past what it has read, and hears how it ended.
actor DownloadRelay {
    private var writer: FileHandle?
    private let inMemory: Bool
    private var memory = Data()
    private var written = 0
    private var done = false
    private var failure: Error?
    private var waiter: CheckedContinuation<Void, Never>?

    init(writer: FileHandle?) {
        self.writer = writer
        inMemory = writer == nil
    }

    func append(_ data: Data) throws {
        if inMemory {
            memory.append(data)
        } else {
            try writer?.write(contentsOf: data)
        }
        written += data.count
        wake()
    }

    /// Closes the partial file; false when there is none to keep.
    func closeFile() -> Bool {
        guard let writer else { return false }
        try? writer.close()
        self.writer = nil
        return true
    }

    /// The end of the download: `nil` when it arrived whole. The first ending counts.
    func finish(_ error: Error?) {
        guard !done else { return }
        done = true
        failure = error
        wake()
    }

    /// Up to `max` bytes after `offset`, waiting for them; nil once everything is read.
    func next(after offset: Int, reader: FileHandle?, max: Int) async throws -> Data? {
        while written <= offset, !done {
            await withCheckedContinuation { waiter = $0 }
        }
        if let failure, failure is CancellationError { throw failure }
        if written > offset {
            if inMemory {
                let data = memory.prefix(max)
                memory.removeFirst(data.count)
                return Data(data)
            }
            guard let reader else { return nil }
            try reader.seek(toOffset: UInt64(offset))
            return try reader.read(upToCount: min(max, written - offset))
        }
        if let failure { throw failure }
        return nil
    }

    private func wake() {
        waiter?.resume()
        waiter = nil
    }
}

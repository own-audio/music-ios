import AVFoundation
import Foundation

/// Cuts a FLAC stream into its frames, for decoding a track while it arrives.
///
/// Core Audio's stream parser finds frames by their sync code alone, and in real music those
/// two bytes also turn up inside frames: the first three megabytes of an ordinary album track
/// held 445 of them, 57 not a frame. Cut there, the decoder loses sync and gives no more audio.
/// A test tone never shows this — it compresses into small frames with no stray sync codes.
///
/// Here a frame ends only where the next header is genuine (its CRC-8 holds) *and* the bytes
/// before it end in the CRC-16 of the frame they close: a false sync passes both by chance
/// about once in sixteen million.
struct FLACFramer {
    private var buffer = Data()
    /// Where the current frame starts in `buffer`, once the metadata is behind.
    private var frameStart: Int?
    private var searchFrom = 0

    /// Bytes in; whole frames out, in order.
    mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        if frameStart == nil {
            guard let audio = Self.audioStart(in: buffer) else { return [] }
            frameStart = audio
            searchFrom = audio + Self.shortestFrame
        }
        return cutFrames()
    }

    /// The rest, once no more bytes are coming: the last frame has no header after it.
    mutating func finish() -> Data? {
        guard let start = frameStart, buffer.count > start else { return nil }
        frameStart = buffer.count
        return buffer.subdata(in: start..<buffer.count)
    }

    /// The samples per channel a frame holds, from its header; `nil` if it isn't a FLAC frame.
    static func blockSize(of frame: Data) -> AVAudioFrameCount? {
        let bytes = [UInt8](frame.prefix(16))
        guard bytes.count >= 6, bytes[0] == 0xFF, bytes[1] & 0xFE == 0xF8 else { return nil }
        let code = bytes[2] >> 4
        switch code {
        case 1: return 192
        case 2...5: return 576 << (code - 2)
        case 8...15: return 256 << (code - 8)
        case 6, 7:
            // Stored after the UTF-8 coded frame number.
            var extra = 0
            if bytes[4] & 0x80 != 0 {
                var mask: UInt8 = 0x40
                while bytes[4] & mask != 0, extra < 6 { extra += 1; mask >>= 1 }
            }
            let at = 5 + extra
            guard bytes.count > at + 1 else { return nil }
            return code == 6 ? AVAudioFrameCount(bytes[at]) + 1 : (AVAudioFrameCount(bytes[at]) << 8 | AVAudioFrameCount(bytes[at + 1])) + 1
        default: return nil
        }
    }

    /// A header and footer at the least.
    private static let shortestFrame = 10

    private mutating func cutFrames() -> [Data] {
        guard var start = frameStart else { return [] }
        var frames: [Data] = []
        var position = max(searchFrom, start + Self.shortestFrame)
        buffer.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            // A header is at most 16 bytes; look only where a whole one has arrived.
            while position + 16 <= bytes.count {
                if bytes[position] == 0xFF, bytes[position + 1] & 0xFE == 0xF8,
                   Self.headerIsGenuine(bytes, at: position),
                   Self.crc16(bytes, from: start, to: position - 2) == UInt16(bytes[position - 2]) << 8 | UInt16(bytes[position - 1]) {
                    frames.append(Data(bytes[start..<position]))
                    start = position
                    position += Self.shortestFrame
                } else {
                    position += 1
                }
            }
        }
        // Keep the buffer from growing with the track: drop what has gone out.
        if start > 0 {
            buffer.removeSubrange(0..<start)
            position -= start
            start = 0
        }
        frameStart = start
        searchFrom = position
        return frames
    }

    /// Past an ID3 tag, "fLaC" and the metadata blocks; `nil` until they have all arrived.
    static func audioStart(in data: Data) -> Int? {
        let bytes = [UInt8](data.prefix(16))
        var offset = 0
        if bytes.count >= 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 { // "ID3"
            let size = Int(bytes[6]) << 21 | Int(bytes[7]) << 14 | Int(bytes[8]) << 7 | Int(bytes[9])
            offset = 10 + size
        }
        guard data.count >= offset + 4 else { return nil }
        let base = data.startIndex
        guard data[base + offset ..< base + offset + 4] == Data("fLaC".utf8) else { return nil }
        offset += 4
        while true {
            guard data.count >= offset + 4 else { return nil }
            let header = data[base + offset]
            let length = Int(data[base + offset + 1]) << 16 | Int(data[base + offset + 2]) << 8 | Int(data[base + offset + 3])
            offset += 4 + length
            if header & 0x80 != 0 { return data.count >= offset ? offset : nil }
        }
    }

    /// The frame header's own checks: no reserved values, and its CRC-8.
    private static func headerIsGenuine(_ bytes: UnsafeBufferPointer<UInt8>, at position: Int) -> Bool {
        let blockSize = bytes[position + 2] >> 4
        let sampleRate = bytes[position + 2] & 0x0F
        let channels = bytes[position + 3] >> 4
        let sampleSize = (bytes[position + 3] >> 1) & 0x07
        guard blockSize != 0, sampleRate != 0x0F, channels <= 10, sampleSize != 3, sampleSize != 7,
              bytes[position + 3] & 1 == 0 else { return false }
        // The frame or sample number, UTF-8 coded: one to seven bytes.
        var length = 4
        let lead = bytes[position + 4]
        var extra = 0
        if lead & 0x80 != 0 {
            var mask: UInt8 = 0x40
            while lead & mask != 0, extra < 6 { extra += 1; mask >>= 1 }
            guard extra > 0 else { return false }
        }
        length += 1 + extra
        if blockSize == 6 { length += 1 } else if blockSize == 7 { length += 2 }
        if sampleRate == 12 { length += 1 } else if sampleRate == 13 || sampleRate == 14 { length += 2 }
        guard position + length < bytes.count else { return false }
        return crc8(bytes, from: position, to: position + length) == bytes[position + length]
    }

    private static func crc8(_ bytes: UnsafeBufferPointer<UInt8>, from: Int, to: Int) -> UInt8 {
        var crc: UInt8 = 0
        for index in from..<to { crc = crc8Table[Int(crc ^ bytes[index])] }
        return crc
    }

    private static func crc16(_ bytes: UnsafeBufferPointer<UInt8>, from: Int, to: Int) -> UInt16 {
        var crc: UInt16 = 0
        for index in from..<to { crc = (crc << 8) ^ crc16Table[Int(UInt8(crc >> 8) ^ bytes[index])] }
        return crc
    }

    private static let crc8Table: [UInt8] = (0..<256).map { value in
        var crc = UInt8(value)
        for _ in 0..<8 { crc = crc & 0x80 != 0 ? (crc << 1) ^ 0x07 : crc << 1 }
        return crc
    }

    private static let crc16Table: [UInt16] = (0..<256).map { value in
        var crc = UInt16(value) << 8
        for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x8005 : crc << 1 }
        return crc
    }
}

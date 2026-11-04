//
//  Tempus patch: accurate seeks in FLAC and VBR MP3.
//  Released under the MIT license, like the rest of AudioStreaming.
//

import Foundation

/// The parts of a FLAC frame header a seek needs. Every frame says where it is in the stream, so
/// after jumping to a guessed byte offset the first frame found there tells the real position.
struct FlacFrameHeader: Equatable {
    /// Where the header starts in the bytes searched.
    let index: Int
    /// The first sample (inter-channel frame) of the frame.
    let sample: Int64

    /// The longest header: sync and codes (4), coded number (7), block size (2), sample rate (2), CRC (1).
    static let maximumSize = 16

    /// Sample rates for the codes that name one; the other codes defer to STREAMINFO or the header.
    private static let sampleRates: [UInt8: Double] = [
        1: 88200, 2: 176_400, 3: 192_000, 4: 8000, 5: 16000, 6: 22050,
        7: 24000, 8: 32000, 9: 44100, 10: 48000, 11: 96000,
    ]

    /// Finds the first valid frame header in `bytes`. Sync codes also turn up inside audio data, so a
    /// candidate needs valid reserved bits, a sample rate that matches the stream, and a good CRC.
    ///
    /// - Parameters:
    ///   - nominalBlockSize: STREAMINFO's block size, which turns a fixed-blocksize frame number into a sample.
    ///   - sampleRate: the stream's sample rate.
    /// - Returns: nil when there is none yet (a candidate cut off by the end of `bytes` counts as none).
    static func find(in bytes: [UInt8], nominalBlockSize: Int64, sampleRate: Double) -> FlacFrameHeader? {
        guard bytes.count >= 2 else { return nil }
        for index in 0 ..< bytes.count - 1 where bytes[index] == 0xFF && bytes[index + 1] & 0xFE == 0xF8 {
            if let header = parse(bytes, at: index, nominalBlockSize: nominalBlockSize, sampleRate: sampleRate) {
                return header
            }
        }
        return nil
    }

    private static func parse(
        _ bytes: [UInt8],
        at start: Int,
        nominalBlockSize: Int64,
        sampleRate: Double
    ) -> FlacFrameHeader? {
        guard start + 4 < bytes.count else { return nil }
        let isVariableBlockSize = bytes[start + 1] & 0x01 == 1
        let blockSizeCode = bytes[start + 2] >> 4
        let sampleRateCode = bytes[start + 2] & 0x0F
        let channels = bytes[start + 3] >> 4
        let sampleSize = (bytes[start + 3] >> 1) & 0x07
        guard blockSizeCode != 0, sampleRateCode != 15, channels <= 10, sampleSize != 3, bytes[start + 3] & 0x01 == 0
        else { return nil }
        if let rate = sampleRates[sampleRateCode], rate != sampleRate {
            return nil
        }

        var cursor = start + 4
        let maximumLength = isVariableBlockSize ? 7 : 6
        guard let number = codedNumber(bytes, at: &cursor, maximumLength: maximumLength) else { return nil }
        cursor += blockSizeCode == 6 ? 1 : blockSizeCode == 7 ? 2 : 0
        cursor += sampleRateCode == 12 ? 1 : sampleRateCode == 13 || sampleRateCode == 14 ? 2 : 0
        guard cursor < bytes.count, crc8(bytes[start ..< cursor]) == bytes[cursor] else { return nil }

        let sample = isVariableBlockSize ? number : number * nominalBlockSize
        return FlacFrameHeader(index: start, sample: sample)
    }

    /// FLAC's UTF-8-like number coding: the first byte's leading 1 bits give the length.
    private static func codedNumber(_ bytes: [UInt8], at cursor: inout Int, maximumLength: Int) -> Int64? {
        guard cursor < bytes.count else { return nil }
        let first = bytes[cursor]
        let length = first < 0x80 ? 1 : (~first).leadingZeroBitCount
        guard length != 1 || first < 0x80, length <= maximumLength, cursor + length <= bytes.count else { return nil }
        var value = length == 1 ? Int64(first) : Int64(first & (0xFF >> (length + 1)))
        for offset in 1 ..< length {
            let byte = bytes[cursor + offset]
            guard byte & 0xC0 == 0x80 else { return nil }
            value = value << 6 | Int64(byte & 0x3F)
        }
        cursor += length
        return value
    }

    /// CRC-8 with polynomial x^8 + x^2 + x + 1, as FLAC frame headers use.
    static func crc8(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        var crc: UInt8 = 0
        for byte in bytes {
            crc ^= byte
            for _ in 0 ..< 8 {
                crc = crc & 0x80 != 0 ? (crc << 1) ^ 0x07 : crc << 1
            }
        }
        return crc
    }
}

/// Homes in on the FLAC frame that holds a target sample. Each landing (the frame found after a
/// jump) narrows the byte range the target lies in, and the next jump interpolates within it.
struct FlacSeekSearch: Equatable {
    /// A frame known to start at `byte` with `sample`.
    struct Anchor: Equatable {
        let byte: Int64
        let sample: Int64
    }

    enum Step: Equatable {
        /// Play from this landing, dropping `skip` samples first.
        case accept(skip: Int64)
        /// Jump to this byte and report the next landing.
        case jump(to: Int64)
    }

    let target: Int64
    /// How far before the target a landing may be and still be played: the gap is decoded and dropped.
    let tolerance: Int64
    private(set) var lower: Anchor
    private(set) var upper: Anchor
    private(set) var jumps = 0
    /// Set once the search stops narrowing and goes back to `lower`, which is never past the target.
    private var isSettling = false

    static let maximumJumps = 10
    /// Below this many bytes the search stops jumping and plays on from `lower`.
    static let settleSpan: Int64 = 256 * 1024

    /// - Parameters:
    ///   - lower: the first frame.
    ///   - upper: the end of the audio data, with the stream's length in samples.
    init(target: Int64, tolerance: Int64, lower: Anchor, upper: Anchor) {
        self.target = max(0, target)
        self.tolerance = max(0, tolerance)
        self.lower = lower
        self.upper = upper
    }

    /// Where to jump first.
    var firstJump: Int64 {
        estimate()
    }

    mutating func landed(at anchor: Anchor) -> Step {
        let previousSpan = upper.byte - lower.byte
        if anchor.sample <= target {
            if isSettling || target - anchor.sample <= tolerance {
                return .accept(skip: target - anchor.sample)
            }
            if anchor.byte >= lower.byte {
                lower = anchor
            }
        } else if anchor.byte < upper.byte {
            upper = anchor
        }
        jumps += 1
        let span = upper.byte - lower.byte
        if jumps >= Self.maximumJumps || span <= Self.settleSpan {
            isSettling = true
            return .jump(to: lower.byte)
        }
        // Interpolation can creep up on the target from one side when the bitrate changes sharply
        // (a quiet intro, then loud). A jump that didn't halve the range is followed by a bisection.
        return .jump(to: span > previousSpan / 2 ? lower.byte + span / 2 : estimate())
    }

    /// Interpolates the byte for a sample a little before the target, so landing there is in tolerance.
    private func estimate() -> Int64 {
        let aim = max(lower.sample, target - tolerance / 2)
        let samples = max(1, upper.sample - lower.sample)
        let fraction = min(1, Double(aim - lower.sample) / Double(samples))
        let byte = lower.byte + Int64(fraction * Double(upper.byte - lower.byte))
        return min(max(byte, lower.byte), max(lower.byte, upper.byte - 1))
    }
}

/// The table of contents in a VBR MP3's Xing (or LAME "Info") header: for each percent of the
/// duration, how far into the file that point is. Without it a seek can only assume a constant
/// bitrate, which in a VBR file can land seconds away from the requested time.
struct XingSeekTable: Equatable {
    /// Where the Xing frame (the first frame) starts, in file bytes.
    let frameStart: Int64
    /// The audio frames after the Xing frame, when the header says.
    let frameCount: Int?
    /// The stream's bytes from `frameStart`, when the header says.
    let byteCount: Int64?
    /// 100 entries, each a fraction of the stream's bytes in 256ths.
    let toc: [UInt8]

    /// How far either side of `dataOffset` to look for the header: more than the largest MP3 frame.
    private static let searchRadius = 2048
    /// A tag, flags, frame and byte counts, and the table.
    private static let headerSize = 4 + 4 + 4 + 4 + 100

    /// Looks for the header in `bytes`, which start at file offset `bytesStart`, near `dataOffset`
    /// (where Core Audio says the audio starts).
    init?(bytes: [UInt8], bytesStart: Int64, dataOffset: Int64) {
        let center = Int(dataOffset - bytesStart)
        let lowest = max(0, center - Self.searchRadius)
        let highest = min(bytes.count - Self.headerSize, center + Self.searchRadius)
        guard lowest <= highest else { return nil }
        for tagIndex in lowest ... highest where Self.isTag(bytes, at: tagIndex) {
            if let table = Self.parse(bytes, tagIndex: tagIndex, bytesStart: bytesStart) {
                self = table
                return
            }
        }
        return nil
    }

    init(frameStart: Int64, frameCount: Int?, byteCount: Int64?, toc: [UInt8]) {
        self.frameStart = frameStart
        self.frameCount = frameCount
        self.byteCount = byteCount
        self.toc = toc
    }

    private static func isTag(_ bytes: [UInt8], at index: Int) -> Bool {
        let tag = bytes[index ..< index + 4]
        return tag.elementsEqual("Xing".utf8) || tag.elementsEqual("Info".utf8)
    }

    private static func parse(_ bytes: [UInt8], tagIndex: Int, bytesStart: Int64) -> XingSeekTable? {
        // The tag follows the 4-byte frame header and the side information, whose size depends on
        // the MPEG version and the channel mode.
        for sideInfo in [32, 17, 9] {
            let frameIndex = tagIndex - 4 - sideInfo
            guard frameIndex >= 0, bytes[frameIndex] == 0xFF, bytes[frameIndex + 1] & 0xE0 == 0xE0 else { continue }
            let isMPEG1 = bytes[frameIndex + 1] & 0x18 == 0x18
            let isMono = bytes[frameIndex + 3] >> 6 == 3
            guard sideInfo == (isMPEG1 ? (isMono ? 17 : 32) : (isMono ? 9 : 17)) else { continue }

            let flags = readUInt32(bytes, at: tagIndex + 4)
            var cursor = tagIndex + 8
            var frameCount: Int?
            var byteCount: Int64?
            if flags & 0x1 != 0 {
                frameCount = Int(readUInt32(bytes, at: cursor))
                cursor += 4
            }
            if flags & 0x2 != 0 {
                byteCount = Int64(readUInt32(bytes, at: cursor))
                cursor += 4
            }
            guard flags & 0x4 != 0, cursor + 100 <= bytes.count else { return nil }
            return XingSeekTable(
                frameStart: bytesStart + Int64(frameIndex),
                frameCount: frameCount.flatMap { $0 > 0 ? $0 : nil },
                byteCount: byteCount.flatMap { $0 > 0 ? $0 : nil },
                toc: Array(bytes[cursor ..< cursor + 100])
            )
        }
        return nil
    }

    private static func readUInt32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        bytes[index ..< index + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// The file offset for `time`, interpolating between table entries as LAME intends.
    ///
    /// - Parameters:
    ///   - frameDuration: one MP3 frame's duration, which with the frame count gives the duration.
    ///   - duration: the stream's duration, for a header without a frame count.
    ///   - fileLength: the file's length, for a header without a byte count.
    func byteOffset(for time: Double, frameDuration: Double, duration: Double, fileLength: Int64) -> Int64? {
        let total = frameCount.map { Double($0) * frameDuration } ?? duration
        let bytes = byteCount ?? (fileLength - frameStart)
        guard total > 0, bytes > 0 else { return nil }
        let percent = min(max(time / total * 100, 0), 100)
        let index = min(Int(percent), 99)
        let previous = Double(toc[index])
        let next = index == 99 ? 256 : Double(toc[index + 1])
        let scaled = previous + (next - previous) * (percent - Double(index))
        let offset = Int64((scaled / 256 * Double(bytes)).rounded())
        return frameStart + min(max(offset, 0), bytes - 1)
    }
}

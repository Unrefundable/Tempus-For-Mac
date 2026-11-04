//
//  Tempus patch: accurate seeks in FLAC and VBR MP3.
//

import XCTest

@testable import AudioStreaming

class FlacFrameHeaderTests: XCTestCase {
    /// A fixed-blocksize header: 4096 samples (code 12), 44.1 kHz (code 9), stereo, 16-bit.
    private func fixedHeader(frame: UInt8) -> [UInt8] {
        withCRC([0xFF, 0xF8, 0xC9, 0x18, frame])
    }

    private func withCRC(_ bytes: [UInt8]) -> [UInt8] {
        bytes + [FlacFrameHeader.crc8(bytes[...])]
    }

    func testTheCRCMatchesTheReferenceValue() {
        // CRC-8/SMBUS (FLAC's) of "123456789" is 0xF4.
        XCTAssertEqual(FlacFrameHeader.crc8(Array("123456789".utf8)[...]), 0xF4)
    }

    func testAFixedBlockSizeFrameNumberBecomesASample() {
        let bytes: [UInt8] = [0x12, 0x34, 0x56] + fixedHeader(frame: 10) + [0, 0]
        let header = FlacFrameHeader.find(in: bytes, nominalBlockSize: 4096, sampleRate: 44100)
        XCTAssertEqual(header, FlacFrameHeader(index: 3, sample: 40960))
    }

    func testAVariableBlockSizeHeaderGivesTheSampleItself() {
        // Sample 0x1F_FFFF needs a 4-byte coded number: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx.
        let bytes = withCRC([0xFF, 0xF9, 0xC9, 0x18, 0xF7, 0xBF, 0xBF, 0xBF])
        let header = FlacFrameHeader.find(in: bytes, nominalBlockSize: 4096, sampleRate: 44100)
        XCTAssertEqual(header?.sample, 0x1F_FFFF)
    }

    func testASyncCodeInsideAudioDataIsSkipped() {
        var corrupt = fixedHeader(frame: 3)
        corrupt[5] ^= 0xFF // bad CRC
        let bytes = corrupt + fixedHeader(frame: 4)
        let header = FlacFrameHeader.find(in: bytes, nominalBlockSize: 4096, sampleRate: 44100)
        XCTAssertEqual(header, FlacFrameHeader(index: 6, sample: 4 * 4096))
    }

    func testAHeaderForAnotherSampleRateIsSkipped() {
        let header = FlacFrameHeader.find(in: fixedHeader(frame: 1), nominalBlockSize: 4096, sampleRate: 48000)
        XCTAssertNil(header)
    }

    func testAHeaderCutOffByTheEndOfTheBytesIsNotFoundYet() {
        let bytes = Array(fixedHeader(frame: 1).dropLast())
        XCTAssertNil(FlacFrameHeader.find(in: bytes, nominalBlockSize: 4096, sampleRate: 44100))
    }

    func testExtraBlockSizeAndSampleRateBytesAreCovered() {
        // Block size code 7 (16 bits follow) and sample rate code 13 (16 bits of Hz follow).
        let bytes = withCRC([0xFF, 0xF8, 0x7D, 0x18, 0x02, 0x11, 0xFF, 0xAC, 0x44])
        let header = FlacFrameHeader.find(in: bytes, nominalBlockSize: 4608, sampleRate: 44100)
        XCTAssertEqual(header?.sample, 2 * 4608)
    }
}

class FlacSeekSearchTests: XCTestCase {
    /// A 300 s, 44.1 kHz stream whose quiet first half packs 5x tighter than its loud second half,
    /// with a frame every 4096 samples: a constant-bitrate guess lands far from the target.
    private struct UnevenStream {
        let rate: Int64 = 44100
        let blockSize: Int64 = 4096
        let dataOffset: Int64 = 8000
        let half: Int64 = 150 * 44100

        func byte(atSample sample: Int64) -> Int64 {
            let first = Double(min(sample, half)) * 0.8
            let second = Double(max(0, sample - half)) * 4
            return dataOffset + Int64(first + second)
        }

        var end: FlacSeekSearch.Anchor {
            .init(byte: byte(atSample: 300 * rate), sample: 300 * rate)
        }

        /// The first frame at or after `byte`, as a seek there would find it.
        func landing(atOrAfter byte: Int64) -> FlacSeekSearch.Anchor {
            var frame: Int64 = 0
            while self.byte(atSample: frame * blockSize) < byte {
                frame += 1
            }
            return .init(byte: self.byte(atSample: frame * blockSize), sample: frame * blockSize)
        }
    }

    private func seek(to seconds: Int64, in stream: UnevenStream) -> (skip: Int64, landing: Int64, jumps: Int)? {
        var search = FlacSeekSearch(
            target: seconds * stream.rate,
            tolerance: 2 * stream.rate,
            lower: .init(byte: stream.dataOffset, sample: 0),
            upper: stream.end
        )
        var byte = search.firstJump
        for _ in 0 ... FlacSeekSearch.maximumJumps + 1 {
            let landing = stream.landing(atOrAfter: byte)
            switch search.landed(at: landing) {
            case let .accept(skip):
                return (skip, landing.sample, search.jumps)
            case let .jump(to: next):
                byte = next
            }
        }
        return nil
    }

    func testTheSearchLandsJustBeforeTheTargetAndDropsTheGap() throws {
        let stream = UnevenStream()
        for seconds: Int64 in [1, 5, 60, 149, 151, 200, 299] {
            let result = try XCTUnwrap(seek(to: seconds, in: stream), "\(seconds) s never settled")
            let target = seconds * stream.rate
            XCTAssertLessThanOrEqual(result.landing, target, "\(seconds) s")
            XCTAssertEqual(result.landing + result.skip, target, "\(seconds) s")
            // Either within tolerance, or close enough in bytes that decoding the gap costs little.
            let bytesToDrop = stream.byte(atSample: target) - stream.byte(atSample: result.landing)
            XCTAssertTrue(
                result.skip <= 2 * stream.rate || bytesToDrop <= FlacSeekSearch.settleSpan,
                "\(seconds) s: dropping \(result.skip) samples, \(bytesToDrop) bytes"
            )
            XCTAssertLessThan(result.jumps, FlacSeekSearch.maximumJumps, "\(seconds) s")
        }
    }

    func testTheStartNeedsNoJump() throws {
        let result = try XCTUnwrap(seek(to: 0, in: UnevenStream()))
        XCTAssertEqual(result.skip, 0)
        XCTAssertEqual(result.jumps, 0)
    }

    func testAfterTooManyJumpsTheSearchPlaysOnFromTheBestFrameBeforeTheTarget() {
        var search = FlacSeekSearch(
            target: 1_000_000,
            tolerance: 10,
            lower: .init(byte: 0, sample: 0),
            upper: .init(byte: 100_000_000, sample: 2_000_000)
        )
        var step = FlacSeekSearch.Step.accept(skip: 0)
        for jump in 0 ..< FlacSeekSearch.maximumJumps {
            // Landings that never get within tolerance: always just past the target.
            step = search.landed(at: .init(byte: 90_000_000 - Int64(jump), sample: 1_000_001))
        }
        XCTAssertEqual(step, .jump(to: 0))
        XCTAssertEqual(search.landed(at: .init(byte: 0, sample: 0)), .accept(skip: 1_000_000))
    }
}

class XingSeekTableTests: XCTestCase {
    /// An MPEG-1 Layer III stereo frame with a Xing header: 1000 frames, 400 000 bytes, and a table of
    /// contents that puts the first half of the duration in the first quarter of the bytes.
    private func xingFrame() -> [UInt8] {
        let header: [UInt8] = [0xFF, 0xFB, 0x90, 0x00]
        let sideInformation = [UInt8](repeating: 0, count: 32)
        let tag: [UInt8] = Array("Xing".utf8) + [0, 0, 0, 0x07]
        let counts: [UInt8] = bigEndian(1000) + bigEndian(400_000)
        let toc: [UInt8] = (0 ..< 100).map { (percent: Int) -> UInt8 in
            UInt8(percent < 50 ? percent * 64 / 50 : 64 + (percent - 50) * 192 / 50)
        }
        let padding = [UInt8](repeating: 0, count: 300)
        return [header, sideInformation, tag, counts, toc, padding].flatMap { $0 }
    }

    private func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    func testTheHeaderIsFoundAfterAnID3Tag() throws {
        let bytes = Array(repeating: 0x20, count: 5000) + xingFrame()
        let table = try XCTUnwrap(XingSeekTable(bytes: bytes, bytesStart: 1000, dataOffset: 6000))
        XCTAssertEqual(table.frameStart, 6000)
        XCTAssertEqual(table.frameCount, 1000)
        XCTAssertEqual(table.byteCount, 400_000)
    }

    func testOffsetsFollowTheTableNotAConstantBitrate() throws {
        let table = try XCTUnwrap(XingSeekTable(bytes: xingFrame(), bytesStart: 0, dataOffset: 0))
        let frameDuration = 1152.0 / 44100
        let duration = 1000 * frameDuration
        // Halfway through the duration is a quarter of the way through the bytes.
        let half = table.byteOffset(for: duration / 2, frameDuration: frameDuration, duration: 0, fileLength: 0)
        XCTAssertEqual(half, 100_000)
        XCTAssertEqual(table.byteOffset(for: 0, frameDuration: frameDuration, duration: 0, fileLength: 0), 0)
        let end = table.byteOffset(for: duration * 2, frameDuration: frameDuration, duration: 0, fileLength: 0)
        XCTAssertEqual(end, 399_999)
    }

    func testAHeaderWithoutATableIsIgnored() {
        var bytes = xingFrame()
        bytes[43] = 0x03 // frames and bytes, but no table of contents
        XCTAssertNil(XingSeekTable(bytes: bytes, bytesStart: 0, dataOffset: 0))
    }

    func testAStreamWithoutAHeaderHasNoTable() {
        let bytes: [UInt8] = [0xFF, 0xFB, 0x90, 0x00] + Array(repeating: 0, count: 600)
        XCTAssertNil(XingSeekTable(bytes: bytes, bytesStart: 0, dataOffset: 0))
    }
}

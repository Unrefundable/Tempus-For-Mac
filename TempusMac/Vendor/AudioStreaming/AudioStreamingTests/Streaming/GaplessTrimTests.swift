//
//  Tempus patch: gapless playback for MP3 and AAC.
//

import XCTest

@testable import AudioStreaming

class GaplessTrimTests: XCTestCase {
    /// Feeds `chunks` through the trim and returns [drop, keep] for each.
    private func run(_ trim: inout GaplessTrim, _ chunks: [Int], ratio: Double = 1) -> [[Int]] {
        chunks.map { count in
            let result = trim.trim(chunkOf: count, outputRatio: ratio)
            return [result.drop, result.keep]
        }
    }

    func testWithoutPacketTableEverythingIsKept() {
        var trim = GaplessTrim()
        XCTAssertEqual(run(&trim, [100, 50]), [[0, 100], [0, 50]])
    }

    func testPrimingIsDroppedAcrossChunks() {
        var trim = GaplessTrim(primingFrames: 150, validFrames: nil)
        XCTAssertEqual(run(&trim, [100, 100, 100]), [[100, 0], [50, 50], [0, 100]])
    }

    func testPaddingAfterValidFramesIsDropped() {
        var trim = GaplessTrim(primingFrames: 10, validFrames: 200)
        // Valid audio is source frames 10..<210.
        XCTAssertEqual(run(&trim, [100, 100, 100]), [[10, 90], [0, 100], [0, 10]])
    }

    func testChunksEntirelyInPaddingKeepNothing() {
        var trim = GaplessTrim(primingFrames: 0, validFrames: 50)
        XCTAssertEqual(run(&trim, [50, 30]), [[0, 50], [0, 0]])
    }

    func testFrameCountsScaleToTheOutputRate() {
        // A 2x output rate doubles every boundary: priming 200, valid audio ends at 800.
        var trim = GaplessTrim(primingFrames: 100, validFrames: 300)
        XCTAssertEqual(run(&trim, [500, 500], ratio: 2), [[200, 300], [0, 300]])
    }

    func testAfterSeekPrimingIsNotDroppedAgainButPaddingStillIs() {
        var trim = GaplessTrim(primingFrames: 100, validFrames: 1000)
        trim.restart(atSourceFrame: 900)
        // Valid audio ends at source frame 1100, 200 frames after the seek point.
        XCTAssertEqual(run(&trim, [150, 150]), [[0, 150], [0, 50]])
    }

    func testAfterAnInexactSeekNothingIsTrimmed() {
        var trim = GaplessTrim(primingFrames: 100, validFrames: 1000)
        trim.stopTrimming()
        XCTAssertFalse(trim.isActive)
        XCTAssertEqual(run(&trim, [5000]), [[0, 5000]])
    }

    func testAnAccurateSeekDropsTheFramesBeforeTheTarget() {
        // A FLAC seek landed on the frame at 4608 for a target of 5000.
        var trim = GaplessTrim()
        trim.restart(atSourceFrame: 4608, keepingFrom: 5000)
        XCTAssertTrue(trim.isActive)
        XCTAssertEqual(run(&trim, [300, 300, 300]), [[300, 0], [92, 208], [0, 300]])
    }

    func testTheKeepPointScalesToTheOutputRate() {
        var trim = GaplessTrim()
        trim.restart(atSourceFrame: 100, keepingFrom: 150)
        XCTAssertEqual(run(&trim, [200], ratio: 2), [[100, 100]])
    }

    func testAnInexactSeekForgetsTheKeepPoint() {
        var trim = GaplessTrim()
        trim.restart(atSourceFrame: 0, keepingFrom: 500)
        trim.stopTrimming()
        trim.restart(atSourceFrame: 1000)
        XCTAssertFalse(trim.isActive)
    }

    func testEmptyChunksAndBadRatiosAreHarmless() {
        var trim = GaplessTrim(primingFrames: 10, validFrames: 10)
        XCTAssertEqual(run(&trim, [0]), [[0, 0]])
        XCTAssertEqual(run(&trim, [40], ratio: 0), [[0, 40]])
    }
}

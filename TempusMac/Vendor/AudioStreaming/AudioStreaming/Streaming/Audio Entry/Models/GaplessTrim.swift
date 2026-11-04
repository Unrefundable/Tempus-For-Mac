//
//  Tempus patch: gapless playback for MP3 and AAC.
//  Released under the MIT license, like the rest of AudioStreaming.
//

import Foundation

/// Drops encoder priming and padding frames, as described by `kAudioFileStreamProperty_PacketTableInfo`,
/// so consecutive tracks join without a gap.
///
/// Frame counts from the packet table are in the source's sample rate. Decoded chunks are in the
/// output's sample rate, so positions are scaled by `outputRatio` (output rate / source rate).
struct GaplessTrim: Equatable {
    /// Frames of encoder delay at the start of the stream, in source frames.
    var primingFrames = 0
    /// Frames of real audio after the priming, in source frames. Nil when the file doesn't say.
    var validFrames: Int?
    /// The source frame at which decoding started (non-zero after a seek).
    private(set) var startFrame = 0
    /// Output frames decoded since `startFrame`, before trimming.
    private(set) var decodedFrames = 0
    /// The first source frame to keep after a seek; earlier frames are dropped.
    private(set) var firstKeptFrame = 0

    var isActive: Bool {
        primingFrames > 0 || validFrames != nil || firstKeptFrame > startFrame
    }

    /// Restarts counting at `sourceFrame`, for example after a seek. Frames before `keptFrom` are
    /// dropped too: an accurate seek may land a little before the requested frame (Tempus patch).
    mutating func restart(atSourceFrame sourceFrame: Int, keepingFrom keptFrom: Int? = nil) {
        startFrame = max(0, sourceFrame)
        decodedFrames = 0
        firstKeptFrame = keptFrom.map { max($0, startFrame) } ?? 0
    }

    /// Keeps every frame from now on, for when the decode position is no longer known exactly.
    mutating func stopTrimming() {
        primingFrames = 0
        validFrames = nil
        firstKeptFrame = 0
    }

    /// For a chunk of `count` decoded output frames, how many to drop from its start and how many to keep
    /// after those. Frames past `drop + keep` are padding and are dropped too.
    mutating func trim(chunkOf count: Int, outputRatio: Double) -> (drop: Int, keep: Int) {
        guard count > 0 else { return (0, 0) }
        let chunkStart = Self.scale(startFrame, outputRatio) + decodedFrames
        let chunkEnd = chunkStart + count
        decodedFrames += count
        guard isActive, outputRatio > 0 else { return (0, count) }

        let keepStart = max(chunkStart, Self.scale(max(primingFrames, firstKeptFrame), outputRatio))
        let keepEnd = validFrames.map { min(chunkEnd, Self.scale(primingFrames + $0, outputRatio)) } ?? chunkEnd
        guard keepEnd > keepStart else { return (min(count, max(0, keepStart - chunkStart)), 0) }
        return (keepStart - chunkStart, keepEnd - keepStart)
    }

    private static func scale(_ sourceFrames: Int, _ ratio: Double) -> Int {
        Int((Double(sourceFrames) * ratio).rounded())
    }
}

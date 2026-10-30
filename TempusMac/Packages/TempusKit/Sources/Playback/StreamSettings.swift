import Foundation
import SubsonicAPI

/// What the server may be asked to transcode to. Opus isn't offered: the player can't decode it.
public enum TranscodeFormat: String, Codable, Sendable, CaseIterable {
    case original = "raw"
    case mp3, aac, flac
}

/// Streaming quality, as upstream's transcoding preferences. Upstream's mobile-data settings apply
/// here to constrained networks: personal hotspots and Low Data Mode.
public struct StreamSettings: Codable, Sendable, Equatable {
    public static let bitrates = [0, 32, 48, 64, 80, 96, 112, 128, 160, 192, 256, 320]
    /// Asked for when a track is in a format the player can't decode (Opus, Vorbis and others).
    public static let playableFallback = StreamQuality.transcoded(format: "mp3", maxBitrate: 320)

    /// Send no format or bitrate, so the server's own transcoding rules apply.
    public var serverDecides: Bool
    public var format: TranscodeFormat
    /// In kbps; 0 for no limit.
    public var maxBitrate: Int
    public var constrainedFormat: TranscodeFormat
    public var constrainedMaxBitrate: Int

    public init(
        serverDecides: Bool = false,
        format: TranscodeFormat = .original,
        maxBitrate: Int = 0,
        constrainedFormat: TranscodeFormat = .original,
        constrainedMaxBitrate: Int = 0
    ) {
        self.serverDecides = serverDecides
        self.format = format
        self.maxBitrate = maxBitrate
        self.constrainedFormat = constrainedFormat
        self.constrainedMaxBitrate = constrainedMaxBitrate
    }

    public func quality(for song: Song, onConstrainedNetwork: Bool) -> StreamQuality {
        if serverDecides {
            let isPlayable = Self.isPlayable(
                suffix: song.transcodedSuffix ?? song.suffix,
                contentType: song.transcodedContentType ?? song.contentType
            )
            return isPlayable ? .serverDefault : Self.playableFallback
        }
        let (format, bitrate) = onConstrainedNetwork ? (constrainedFormat, constrainedMaxBitrate) : (format, maxBitrate)
        guard format != .original else {
            let isPlayable = Self.isPlayable(suffix: song.suffix, contentType: song.contentType)
            return isPlayable ? .original : Self.playableFallback
        }
        return .transcoded(format: format.rawValue, maxBitrate: max(0, bitrate))
    }

    /// What Core Audio decodes and AudioStreaming can seek in. A track that says nothing is assumed fine.
    static func isPlayable(suffix: String?, contentType: String?) -> Bool {
        if let suffix {
            return playableSuffixes.contains(suffix.lowercased())
        }
        if let contentType {
            return playableContentTypes.contains(contentType.lowercased())
        }
        return true
    }

    private static let playableSuffixes: Set = [
        "mp3", "m4a", "m4b", "mp4", "aac", "alac", "flac", "wav", "wave", "aif", "aiff", "aifc", "caf",
    ]
    private static let playableContentTypes: Set = [
        "audio/mpeg", "audio/mp3", "audio/mp4", "audio/x-m4a", "audio/m4a", "audio/aac", "audio/aacp",
        "audio/flac", "audio/x-flac", "audio/wav", "audio/x-wav", "audio/wave", "audio/aiff", "audio/x-aiff",
    ]
}

import Foundation

/// A track or directory entry (Subsonic `Child`).
public struct Song: Decodable, Sendable, Hashable, Identifiable {
    @LenientString public var id: String
    @LenientOptionalString public var parentID: String?
    public let isDir: Bool?
    public let title: String?
    public let album: String?
    public let artist: String?
    public let track: Int?
    public let year: Int?
    public let genre: String?
    @LenientOptionalString public var coverArtID: String?
    public let size: Int64?
    public let contentType: String?
    public let suffix: String?
    public let transcodedContentType: String?
    public let transcodedSuffix: String?
    /// Seconds.
    public let duration: Int?
    /// Kilobits per second.
    public let bitrate: Int?
    public let samplingRate: Int?
    public let bitDepth: Int?
    public let path: String?
    public let isVideo: Bool?
    public let userRating: Int?
    public let averageRating: Double?
    public let playCount: Int64?
    public let discNumber: Int?
    @LenientDate public var created: Date?
    @LenientDate public var starred: Date?
    @LenientOptionalString public var albumID: String?
    @LenientOptionalString public var artistID: String?
    /// `music`, `podcast`, `audiobook` or `video`.
    public let type: String?
    /// Milliseconds.
    public let bookmarkPosition: Int64?
    public let replayGain: ReplayGain?
    private let displayAlbumArtist: String?
    private let legacyAlbumArtist: String?

    /// OpenSubsonic's `displayAlbumArtist`, falling back to the older `albumArtist`, as upstream does.
    public var albumArtist: String? {
        displayAlbumArtist ?? legacyAlbumArtist
    }

    private enum CodingKeys: String, CodingKey {
        case id, isDir, title, album, artist, track, year, genre, size, contentType, suffix
        case transcodedContentType, transcodedSuffix, duration, samplingRate, bitDepth, path, isVideo
        case userRating, averageRating, playCount, discNumber, created, starred, type, bookmarkPosition
        case replayGain, displayAlbumArtist
        case parentID = "parent"
        case coverArtID = "coverArt"
        case bitrate = "bitRate"
        case albumID = "albumId"
        case artistID = "artistId"
        case legacyAlbumArtist = "albumArtist"
    }
}

/// Loudness values in dB (gains) and linear amplitude (peaks).
public struct ReplayGain: Decodable, Sendable, Hashable {
    public let trackGain: Double?
    public let albumGain: Double?
    public let trackPeak: Double?
    public let albumPeak: Double?
    public let baseGain: Double?
    public let fallbackGain: Double?
}

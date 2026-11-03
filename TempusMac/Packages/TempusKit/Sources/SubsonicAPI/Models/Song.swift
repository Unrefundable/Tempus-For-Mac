import Foundation

/// A track or directory entry (Subsonic `Child`).
public struct Song: Codable, Sendable, Hashable, Identifiable {
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

    /// For previews, tests and locally built entries. Servers' songs come from decoding.
    public init(
        id: String,
        title: String? = nil,
        album: String? = nil,
        artist: String? = nil,
        albumArtist: String? = nil,
        track: Int? = nil,
        year: Int? = nil,
        genre: String? = nil,
        coverArtID: String? = nil,
        suffix: String? = nil,
        contentType: String? = nil,
        duration: Int? = nil,
        bitrate: Int? = nil,
        samplingRate: Int? = nil,
        bitDepth: Int? = nil,
        discNumber: Int? = nil,
        starred: Date? = nil,
        userRating: Int? = nil,
        albumID: String? = nil,
        artistID: String? = nil,
        type: String? = "music",
        replayGain: ReplayGain? = nil,
        path: String? = nil,
        size: Int64? = nil,
        bookmarkPosition: Int64? = nil
    ) {
        _id = LenientString(wrappedValue: id)
        _parentID = LenientOptionalString(wrappedValue: albumID)
        isDir = false
        self.title = title
        self.album = album
        self.artist = artist
        self.track = track
        self.year = year
        self.genre = genre
        _coverArtID = LenientOptionalString(wrappedValue: coverArtID)
        self.size = size
        self.contentType = contentType
        self.suffix = suffix
        transcodedContentType = nil
        transcodedSuffix = nil
        self.duration = duration
        self.bitrate = bitrate
        self.samplingRate = samplingRate
        self.bitDepth = bitDepth
        self.path = path
        isVideo = false
        self.userRating = userRating
        averageRating = nil
        playCount = nil
        self.discNumber = discNumber
        _created = LenientDate(wrappedValue: nil)
        _starred = LenientDate(wrappedValue: starred)
        _albumID = LenientOptionalString(wrappedValue: albumID)
        _artistID = LenientOptionalString(wrappedValue: artistID)
        self.type = type
        self.bookmarkPosition = bookmarkPosition
        self.replayGain = replayGain
        displayAlbumArtist = albumArtist
        legacyAlbumArtist = nil
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
public struct ReplayGain: Codable, Sendable, Hashable {
    public let trackGain: Double?
    public let albumGain: Double?
    public let trackPeak: Double?
    public let albumPeak: Double?
    public let baseGain: Double?
    public let fallbackGain: Double?
}

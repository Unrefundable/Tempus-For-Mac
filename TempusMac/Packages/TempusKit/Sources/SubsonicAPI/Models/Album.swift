import Foundation

/// An album organised by ID3 tags (Subsonic `AlbumID3` / `AlbumWithSongsID3`).
public struct Album: Decodable, Sendable, Hashable, Identifiable {
    @LenientString public var id: String
    public let name: String?
    public let artist: String?
    @LenientOptionalString public var artistID: String?
    @LenientOptionalString public var coverArtID: String?
    public let songCount: Int?
    /// Seconds.
    public let duration: Int?
    public let playCount: Int64?
    @LenientDate public var created: Date?
    @LenientDate public var starred: Date?
    @LenientDate public var played: Date?
    public let year: Int?
    public let genre: String?
    public let userRating: Int?
    @OneOrMany public var genres: [NamedGenre]
    @OneOrMany public var artists: [Artist]
    public let displayArtist: String?
    @OneOrMany public var releaseTypes: [String]
    @OneOrMany public var moods: [String]
    public let sortName: String?
    public let originalReleaseDate: ReleaseDate?
    public let releaseDate: ReleaseDate?
    public let isCompilation: Bool?
    @OneOrMany public var discTitles: [DiscTitle]
    public let musicBrainzID: String?
    /// Present on `getAlbum`, empty in lists.
    @OneOrMany public var songs: [Song]

    private enum CodingKeys: String, CodingKey {
        case id, name, artist, songCount, duration, playCount, created, starred, played, year, genre
        case userRating, genres, artists, displayArtist, releaseTypes, moods, sortName
        case originalReleaseDate, releaseDate, isCompilation, discTitles
        case artistID = "artistId"
        case coverArtID = "coverArt"
        case musicBrainzID = "musicBrainzId"
        case songs = "song"
    }
}

/// An OpenSubsonic `ItemGenre`.
public struct NamedGenre: Decodable, Sendable, Hashable {
    public let name: String?
}

/// An OpenSubsonic `ItemDate`; any part may be missing.
public struct ReleaseDate: Decodable, Sendable, Hashable {
    public let year: Int?
    public let month: Int?
    public let day: Int?

    public init(year: Int?, month: Int?, day: Int?) {
        self.year = year
        self.month = month
        self.day = day
    }
}

public struct DiscTitle: Decodable, Sendable, Hashable {
    public let disc: Int?
    public let title: String?
}

/// Notes and images from `getAlbumInfo2`.
public struct AlbumInfo: Decodable, Sendable, Hashable {
    public let notes: String?
    public let musicBrainzID: String?
    public let lastFmURL: URL?
    public let smallImageURL: URL?
    public let mediumImageURL: URL?
    public let largeImageURL: URL?

    private enum CodingKeys: String, CodingKey {
        case notes
        case musicBrainzID = "musicBrainzId"
        case lastFmURL = "lastFmUrl"
        case smallImageURL = "smallImageUrl"
        case mediumImageURL = "mediumImageUrl"
        case largeImageURL = "largeImageUrl"
    }
}

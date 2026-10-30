import Foundation

/// An artist organised by ID3 tags (Subsonic `ArtistID3` / `ArtistWithAlbumsID3`).
public struct Artist: Decodable, Sendable, Hashable, Identifiable {
    @LenientString public var id: String
    public let name: String?
    @LenientOptionalString public var coverArtID: String?
    public let albumCount: Int?
    @LenientDate public var starred: Date?
    public let userRating: Int?
    public let imageURL: URL?
    /// Present on `getArtist`, empty in lists.
    @OneOrMany public var albums: [Album]
    @OneOrMany public var appearsOn: [Album]

    private enum CodingKeys: String, CodingKey {
        case id, name, albumCount, starred, userRating, appearsOn
        case coverArtID = "coverArt"
        case imageURL = "artistImageUrl"
        case albums = "album"
    }
}

/// `getArtists`: artists grouped under index letters.
public struct ArtistIndexes: Decodable, Sendable, Hashable {
    public let ignoredArticles: String?
    @OneOrMany public var indexes: [ArtistIndex]

    private enum CodingKeys: String, CodingKey {
        case ignoredArticles
        case indexes = "index"
    }
}

public struct ArtistIndex: Decodable, Sendable, Hashable {
    public let name: String?
    @OneOrMany public var artists: [Artist]

    private enum CodingKeys: String, CodingKey {
        case name
        case artists = "artist"
    }
}

/// Biography, images and similar artists from `getArtistInfo2`.
public struct ArtistInfo: Decodable, Sendable, Hashable {
    public let biography: String?
    public let musicBrainzID: String?
    public let lastFmURL: URL?
    public let smallImageURL: URL?
    public let mediumImageURL: URL?
    public let largeImageURL: URL?
    @OneOrMany public var similarArtists: [Artist]

    private enum CodingKeys: String, CodingKey {
        case biography
        case musicBrainzID = "musicBrainzId"
        case lastFmURL = "lastFmUrl"
        case smallImageURL = "smallImageUrl"
        case mediumImageURL = "mediumImageUrl"
        case largeImageURL = "largeImageUrl"
        case similarArtists = "similarArtist"
    }
}

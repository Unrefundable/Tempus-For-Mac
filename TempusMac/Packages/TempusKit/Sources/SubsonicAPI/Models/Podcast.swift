import Foundation

public struct PodcastChannel: Decodable, Sendable, Hashable, Identifiable {
    @LenientString public var id: String
    public let url: URL?
    public let title: String?
    public let description: String?
    @LenientOptionalString public var coverArtID: String?
    public let originalImageURL: URL?
    /// `new`, `downloading`, `completed`, `error`, `deleted` or `skipped`.
    public let status: String?
    public let errorMessage: String?
    @OneOrMany public var episodes: [PodcastEpisode]

    private enum CodingKeys: String, CodingKey {
        case id, url, title, description, status, errorMessage
        case coverArtID = "coverArt"
        case originalImageURL = "originalImageUrl"
        case episodes = "episode"
    }
}

public struct PodcastEpisode: Decodable, Sendable, Hashable, Identifiable {
    @LenientString public var id: String
    /// The id to stream; absent until the server has downloaded the episode.
    @LenientOptionalString public var streamID: String?
    @LenientOptionalString public var channelID: String?
    public let title: String?
    public let description: String?
    @LenientDate public var publishDate: Date?
    public let status: String?
    @LenientOptionalString public var parentID: String?
    public let isDir: Bool?
    public let album: String?
    public let artist: String?
    public let year: Int?
    public let genre: String?
    @LenientOptionalString public var coverArtID: String?
    public let size: Int64?
    public let contentType: String?
    public let suffix: String?
    /// Seconds.
    public let duration: Int?
    public let bitrate: Int?
    public let path: String?
    @LenientDate public var created: Date?

    private enum CodingKeys: String, CodingKey {
        case id, title, description, publishDate, status, isDir, album, artist, year, genre
        case size, contentType, suffix, duration, path, created
        case streamID = "streamId"
        case channelID = "channelId"
        case parentID = "parent"
        case coverArtID = "coverArt"
        case bitrate = "bitRate"
    }
}

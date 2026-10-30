import Foundation

public struct Playlist: Decodable, Sendable, Hashable, Identifiable {
    @LenientString public var id: String
    public let name: String?
    public let comment: String?
    public let owner: String?
    public let isPublic: Bool?
    public let songCount: Int?
    /// Seconds.
    public let duration: Int?
    @LenientDate public var created: Date?
    @LenientDate public var changed: Date?
    @LenientOptionalString public var coverArtID: String?
    @OneOrMany public var allowedUsers: [String]
    /// Present on `getPlaylist`, empty in lists. Duplicates are kept in order.
    @OneOrMany public var entries: [Song]

    private enum CodingKeys: String, CodingKey {
        case id, name, comment, owner, songCount, duration, created, changed
        case isPublic = "public"
        case coverArtID = "coverArt"
        case allowedUsers = "allowedUser"
        case entries = "entry"
    }
}

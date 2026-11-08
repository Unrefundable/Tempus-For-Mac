import Foundation

/// A server-side internet radio station.
public struct InternetRadioStation: Decodable, Sendable, Hashable, Identifiable {
    @LenientString public var id: String
    public let name: String?
    public let streamURL: URL?
    public let homePageURL: URL?

    private enum CodingKeys: String, CodingKey {
        case id, name
        case streamURL = "streamUrl"
        case homePageURL = "homePageUrl"
    }
}

/// A saved position in a long track (podcast, audiobook), from `getBookmarks`.
public struct Bookmark: Decodable, Sendable, Hashable {
    public let entry: Song
    /// Milliseconds.
    public let position: Int64
    public let username: String?
    public let comment: String?
    @LenientDate public var created: Date?
    @LenientDate public var changed: Date?
}

/// The queue saved on the server with `savePlayQueue`.
public struct PlayQueue: Decodable, Sendable, Hashable {
    @OneOrMany public var entries: [Song]
    /// The id of the current song.
    @LenientOptionalString public var current: String?
    /// Milliseconds into the current song.
    public let position: Int64?
    public let username: String?
    @LenientDate public var changed: Date?
    public let changedBy: String?

    private enum CodingKeys: String, CodingKey {
        case current, position, username, changed, changedBy
        case entries = "entry"
    }
}

public struct Share: Decodable, Sendable, Hashable, Identifiable {
    @LenientString public var id: String
    public let url: URL?
    public let description: String?
    public let username: String?
    @LenientDate public var created: Date?
    @LenientDate public var expires: Date?
    @LenientDate public var lastVisited: Date?
    public let visitCount: Int?
    @OneOrMany public var entries: [Song]

    private enum CodingKeys: String, CodingKey {
        case id, url, description, username, created, expires, lastVisited, visitCount
        case entries = "entry"
    }
}

/// `search3` and `getStarred2` results.
public struct SearchResult: Decodable, Sendable, Hashable {
    @OneOrMany public var artists: [Artist]
    @OneOrMany public var albums: [Album]
    @OneOrMany public var songs: [Song]

    private enum CodingKeys: String, CodingKey {
        case artists = "artist"
        case albums = "album"
        case songs = "song"
    }
}

public struct ScanStatus: Decodable, Sendable, Hashable {
    public let isScanning: Bool
    public let count: Int64?
    /// When the last scan finished, as the server wrote it; OpenSubsonic servers such as
    /// Navidrome send it. Compared only to tell whether the library changed.
    public let lastScan: String?

    public init(isScanning: Bool, count: Int64?, lastScan: String? = nil) {
        self.isScanning = isScanning
        self.count = count
        self.lastScan = lastScan
    }

    private enum CodingKeys: String, CodingKey {
        case count, lastScan
        case isScanning = "scanning"
    }
}

public struct OpenSubsonicExtension: Decodable, Sendable, Hashable {
    public let name: String
    @OneOrMany public var versions: [Int]
}

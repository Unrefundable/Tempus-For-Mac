import Foundation

/// A top-level library ("music folder"). Tempus shows these as library folders.
public struct MusicFolder: Decodable, Sendable, Hashable, Identifiable {
    @LenientString public var id: String
    public let name: String?
}

public struct Genre: Decodable, Sendable, Hashable {
    public let name: String
    public let songCount: Int?
    public let albumCount: Int?

    public init(name: String, songCount: Int?, albumCount: Int?) {
        self.name = name
        self.songCount = songCount
        self.albumCount = albumCount
    }

    private enum CodingKeys: String, CodingKey {
        case songCount, albumCount
        case name = "value"
    }
}

/// `getIndexes`: the folder-based library root.
public struct FolderIndexes: Decodable, Sendable, Hashable {
    public let ignoredArticles: String?
    /// Milliseconds since 1970.
    public let lastModified: Int64?
    @OneOrMany public var shortcuts: [FolderEntry]
    @OneOrMany public var indexes: [FolderIndex]
    /// Files that sit directly in the music folder root.
    @OneOrMany public var children: [Song]

    private enum CodingKeys: String, CodingKey {
        case ignoredArticles, lastModified
        case shortcuts = "shortcut"
        case indexes = "index"
        case children = "child"
    }
}

public struct FolderIndex: Decodable, Sendable, Hashable {
    public let name: String?
    @OneOrMany public var artists: [FolderEntry]

    private enum CodingKeys: String, CodingKey {
        case name
        case artists = "artist"
    }
}

/// A top-level folder in a folder index (Subsonic `Artist`, not `ArtistID3`).
public struct FolderEntry: Decodable, Sendable, Hashable, Identifiable {
    @LenientString public var id: String
    public let name: String?
    @LenientDate public var starred: Date?
    public let userRating: Int?
    public let averageRating: Double?
}

/// `getMusicDirectory`: one folder's sub-folders and files.
public struct Directory: Decodable, Sendable, Hashable, Identifiable {
    @LenientString public var id: String
    @LenientOptionalString public var parentID: String?
    public let name: String?
    @LenientDate public var starred: Date?
    public let userRating: Int?
    public let averageRating: Double?
    public let playCount: Int64?
    @OneOrMany public var children: [Song]

    private enum CodingKeys: String, CodingKey {
        case id, name, starred, userRating, averageRating, playCount
        case parentID = "parent"
        case children = "child"
    }
}

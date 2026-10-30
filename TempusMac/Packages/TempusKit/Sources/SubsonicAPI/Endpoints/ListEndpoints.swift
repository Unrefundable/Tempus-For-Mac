import Foundation

// Album and song lists, starred items and search.

/// The `type` of a `getAlbumList2` request.
public enum AlbumListType: Sendable, Hashable {
    case random, newest, highest, frequent, recent, alphabeticalByName, alphabeticalByArtist, starred
    case byYear(from: Int, to: Int)
    case byGenre(String)

    /// The API's name for this list type.
    var name: String {
        switch self {
        case .random: "random"
        case .newest: "newest"
        case .highest: "highest"
        case .frequent: "frequent"
        case .recent: "recent"
        case .alphabeticalByName: "alphabeticalByName"
        case .alphabeticalByArtist: "alphabeticalByArtist"
        case .starred: "starred"
        case .byYear: "byYear"
        case .byGenre: "byGenre"
        }
    }

    fileprivate var parameters: [URLQueryItem] {
        switch self {
        case let .byYear(from, to): query(("type", name), ("fromYear", from), ("toYear", to))
        case let .byGenre(genre): query(("type", name), ("genre", genre))
        default: query(("type", name))
        }
    }
}

public extension SubsonicRequest where Response == [Album] {
    static func albumList(
        _ type: AlbumListType,
        size: Int = 10,
        offset: Int = 0,
        musicFolderID: String? = nil
    ) -> Self {
        Self(
            method: "getAlbumList2",
            parameters: type.parameters + query(("size", size), ("offset", offset), ("musicFolderId", musicFolderID)),
            elementPath: ["albumList2", "album"]
        )
    }
}

public extension SubsonicRequest where Response == [Song] {
    static func randomSongs(
        size: Int = 10,
        fromYear: Int? = nil,
        toYear: Int? = nil,
        genre: String? = nil,
        musicFolderID: String? = nil
    ) -> Self {
        Self(
            method: "getRandomSongs",
            parameters: query(
                ("size", size), ("fromYear", fromYear), ("toYear", toYear), ("genre", genre),
                ("musicFolderId", musicFolderID)
            ),
            elementPath: ["randomSongs", "song"]
        )
    }

    static func songsByGenre(_ genre: String, count: Int = 10, offset: Int = 0, musicFolderID: String? = nil) -> Self {
        Self(
            method: "getSongsByGenre",
            parameters: query(("genre", genre), ("count", count), ("offset", offset), ("musicFolderId", musicFolderID)),
            elementPath: ["songsByGenre", "song"]
        )
    }

    /// Songs similar to a song, album or artist (Instant Mix from a track).
    static func similarSongs(id: String, count: Int = 50) -> Self {
        Self(
            method: "getSimilarSongs",
            parameters: query(("id", id), ("count", count)),
            elementPath: ["similarSongs", "song"]
        )
    }

    /// Songs similar to an artist, by ID3 tags (Instant Mix from an artist or album).
    static func similarSongs(artistID: String, count: Int = 50) -> Self {
        Self(
            method: "getSimilarSongs2",
            parameters: query(("id", artistID), ("count", count)),
            elementPath: ["similarSongs2", "song"]
        )
    }

    static func topSongs(artist: String, count: Int = 50) -> Self {
        Self(
            method: "getTopSongs",
            parameters: query(("artist", artist), ("count", count)),
            elementPath: ["topSongs", "song"]
        )
    }
}

public extension SubsonicRequest where Response == SearchResult {
    static func starred(musicFolderID: String? = nil) -> Self {
        Self(method: "getStarred2", parameters: query(("musicFolderId", musicFolderID)), elementPath: ["starred2"])
    }

    static func search(
        _ text: String,
        artistCount: Int = 20,
        artistOffset: Int = 0,
        albumCount: Int = 20,
        albumOffset: Int = 0,
        songCount: Int = 20,
        songOffset: Int = 0,
        musicFolderID: String? = nil
    ) -> Self {
        Self(
            method: "search3",
            parameters: query(
                ("query", text), ("artistCount", artistCount), ("artistOffset", artistOffset),
                ("albumCount", albumCount), ("albumOffset", albumOffset),
                ("songCount", songCount), ("songOffset", songOffset), ("musicFolderId", musicFolderID)
            ),
            elementPath: ["searchResult3"]
        )
    }
}

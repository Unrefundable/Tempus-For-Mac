import Foundation

// Browsing: https://opensubsonic.netlify.app/categories/browsing/

public extension SubsonicRequest where Response == [MusicFolder] {
    static var musicFolders: Self {
        Self(method: "getMusicFolders", elementPath: ["musicFolders", "musicFolder"])
    }
}

public extension SubsonicRequest where Response == [Genre] {
    static var genres: Self {
        Self(method: "getGenres", elementPath: ["genres", "genre"])
    }
}

public extension SubsonicRequest where Response == ArtistIndexes {
    static func artists(musicFolderID: String? = nil) -> Self {
        Self(method: "getArtists", parameters: query(("musicFolderId", musicFolderID)), elementPath: ["artists"])
    }
}

public extension SubsonicRequest where Response == FolderIndexes {
    static func indexes(musicFolderID: String? = nil) -> Self {
        Self(method: "getIndexes", parameters: query(("musicFolderId", musicFolderID)), elementPath: ["indexes"])
    }
}

public extension SubsonicRequest where Response == Directory {
    static func musicDirectory(id: String) -> Self {
        Self(method: "getMusicDirectory", parameters: query(("id", id)), elementPath: ["directory"])
    }
}

public extension SubsonicRequest where Response == Artist {
    static func artist(id: String) -> Self {
        Self(method: "getArtist", parameters: query(("id", id)), elementPath: ["artist"])
    }
}

public extension SubsonicRequest where Response == Album {
    static func album(id: String) -> Self {
        Self(method: "getAlbum", parameters: query(("id", id)), elementPath: ["album"])
    }
}

public extension SubsonicRequest where Response == Song {
    static func song(id: String) -> Self {
        Self(method: "getSong", parameters: query(("id", id)), elementPath: ["song"])
    }
}

public extension SubsonicRequest where Response == ArtistInfo {
    static func artistInfo(id: String) -> Self {
        Self(method: "getArtistInfo2", parameters: query(("id", id)), elementPath: ["artistInfo2"])
    }
}

public extension SubsonicRequest where Response == AlbumInfo {
    static func albumInfo(id: String) -> Self {
        Self(method: "getAlbumInfo2", parameters: query(("id", id)), elementPath: ["albumInfo"])
    }
}

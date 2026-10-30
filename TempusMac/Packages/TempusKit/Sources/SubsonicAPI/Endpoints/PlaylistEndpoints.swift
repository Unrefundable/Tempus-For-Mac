import Foundation

public extension SubsonicRequest where Response == [Playlist] {
    static var playlists: Self {
        Self(method: "getPlaylists", elementPath: ["playlists", "playlist"])
    }
}

public extension SubsonicRequest where Response == Playlist {
    static func playlist(id: String) -> Self {
        Self(method: "getPlaylist", parameters: query(("id", id)), elementPath: ["playlist"])
    }
}

public extension SubsonicRequest where Response == EmptyResponse {
    /// Older servers return nothing on create, so the new playlist is not read back.
    static func createPlaylist(name: String, songIDs: [String] = []) -> Self {
        Self(method: "createPlaylist", parameters: query(("name", name)) + repeated("songId", songIDs))
    }

    /// Indexes refer to positions in the playlist before this update.
    static func updatePlaylist(
        id: String,
        name: String? = nil,
        comment: String? = nil,
        isPublic: Bool? = nil,
        songIDsToAdd: [String] = [],
        songIndexesToRemove: [Int] = []
    ) -> Self {
        Self(
            method: "updatePlaylist",
            parameters: query(("playlistId", id), ("name", name), ("comment", comment), ("public", isPublic))
                + repeated("songIdToAdd", songIDsToAdd)
                + repeated("songIndexToRemove", songIndexesToRemove)
        )
    }

    static func deletePlaylist(id: String) -> Self {
        Self(method: "deletePlaylist", parameters: query(("id", id)))
    }
}

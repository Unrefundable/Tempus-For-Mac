import Foundation

public extension SubsonicRequest where Response == [Bookmark] {
    static var bookmarks: Self {
        Self(method: "getBookmarks", elementPath: ["bookmarks", "bookmark"])
    }
}

public extension SubsonicRequest where Response == PlayQueue? {
    /// `nil` when nothing has been saved.
    static var playQueue: Self {
        Self(method: "getPlayQueue", elementPath: ["playQueue"])
    }
}

public extension SubsonicRequest where Response == EmptyResponse {
    /// `position` is in milliseconds.
    static func createBookmark(id: String, position: Int64, comment: String? = nil) -> Self {
        Self(method: "createBookmark", parameters: query(("id", id), ("position", position), ("comment", comment)))
    }

    static func deleteBookmark(id: String) -> Self {
        Self(method: "deleteBookmark", parameters: query(("id", id)))
    }

    /// `position` is milliseconds into `current`.
    static func savePlayQueue(songIDs: [String], current: String? = nil, position: Int64? = nil) -> Self {
        Self(
            method: "savePlayQueue",
            parameters: repeated("id", songIDs) + query(("current", current), ("position", position))
        )
    }
}

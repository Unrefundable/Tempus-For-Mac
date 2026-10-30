import Foundation

public extension SubsonicRequest where Response == EmptyResponse {
    static func star(songIDs: [String] = [], albumIDs: [String] = [], artistIDs: [String] = []) -> Self {
        Self(method: "star", parameters: annotationTargets(songIDs, albumIDs, artistIDs))
    }

    static func unstar(songIDs: [String] = [], albumIDs: [String] = [], artistIDs: [String] = []) -> Self {
        Self(method: "unstar", parameters: annotationTargets(songIDs, albumIDs, artistIDs))
    }

    /// `rating` is clamped to 0...5; 0 removes the rating.
    static func setRating(id: String, rating: Int) -> Self {
        Self(method: "setRating", parameters: query(("id", id), ("rating", min(max(rating, 0), 5))))
    }

    /// `submission: false` reports "now playing"; `true` records a play.
    static func scrobble(id: String, time: Date? = nil, submission: Bool = true) -> Self {
        Self(
            method: "scrobble",
            parameters: query(("id", id), ("time", milliseconds(time)), ("submission", submission))
        )
    }

    private static func annotationTargets(
        _ songs: [String],
        _ albums: [String],
        _ artists: [String]
    ) -> [URLQueryItem] {
        repeated("id", songs) + repeated("albumId", albums) + repeated("artistId", artists)
    }
}

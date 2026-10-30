import Foundation

public extension SubsonicRequest where Response == [PodcastChannel] {
    static func podcasts(includeEpisodes: Bool = true, id: String? = nil) -> Self {
        Self(
            method: "getPodcasts",
            parameters: query(("includeEpisodes", includeEpisodes), ("id", id)),
            elementPath: ["podcasts", "channel"]
        )
    }
}

public extension SubsonicRequest where Response == [PodcastEpisode] {
    static func newestPodcasts(count: Int = 20) -> Self {
        Self(
            method: "getNewestPodcasts",
            parameters: query(("count", count)),
            elementPath: ["newestPodcasts", "episode"]
        )
    }
}

public extension SubsonicRequest where Response == EmptyResponse {
    static var refreshPodcasts: Self {
        Self(method: "refreshPodcasts")
    }

    static func createPodcastChannel(url: URL) -> Self {
        Self(method: "createPodcastChannel", parameters: query(("url", url.absoluteString)))
    }

    static func deletePodcastChannel(id: String) -> Self {
        Self(method: "deletePodcastChannel", parameters: query(("id", id)))
    }

    static func deletePodcastEpisode(id: String) -> Self {
        Self(method: "deletePodcastEpisode", parameters: query(("id", id)))
    }

    /// Asks the server to download the episode; it streams once the episode has a `streamID`.
    static func downloadPodcastEpisode(id: String) -> Self {
        Self(method: "downloadPodcastEpisode", parameters: query(("id", id)))
    }
}

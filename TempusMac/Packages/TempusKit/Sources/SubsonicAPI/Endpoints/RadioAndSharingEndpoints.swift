import Foundation

public extension SubsonicRequest where Response == [InternetRadioStation] {
    static var internetRadioStations: Self {
        Self(method: "getInternetRadioStations", elementPath: ["internetRadioStations", "internetRadioStation"])
    }
}

public extension SubsonicRequest where Response == [Share] {
    static var shares: Self {
        Self(method: "getShares", elementPath: ["shares", "share"])
    }

    /// Returns the new share, including its public `url`.
    static func createShare(ids: [String], description: String? = nil, expires: Date? = nil) -> Self {
        Self(
            method: "createShare",
            parameters: repeated("id", ids) + query(("description", description), ("expires", milliseconds(expires))),
            elementPath: ["shares", "share"]
        )
    }
}

public extension SubsonicRequest where Response == EmptyResponse {
    /// The parameter is spelled `homepageUrl` in requests but `homePageUrl` in responses.
    static func createInternetRadioStation(streamURL: URL, name: String, homePageURL: URL? = nil) -> Self {
        Self(
            method: "createInternetRadioStation",
            parameters: query(
                ("streamUrl", streamURL.absoluteString), ("name", name), ("homepageUrl", homePageURL?.absoluteString)
            )
        )
    }

    static func updateInternetRadioStation(id: String, streamURL: URL, name: String, homePageURL: URL? = nil) -> Self {
        Self(
            method: "updateInternetRadioStation",
            parameters: query(
                ("id", id), ("streamUrl", streamURL.absoluteString), ("name", name),
                ("homepageUrl", homePageURL?.absoluteString)
            )
        )
    }

    static func deleteInternetRadioStation(id: String) -> Self {
        Self(method: "deleteInternetRadioStation", parameters: query(("id", id)))
    }

    static func updateShare(id: String, description: String? = nil, expires: Date? = nil) -> Self {
        Self(
            method: "updateShare",
            parameters: query(("id", id), ("description", description), ("expires", milliseconds(expires)))
        )
    }

    static func deleteShare(id: String) -> Self {
        Self(method: "deleteShare", parameters: query(("id", id)))
    }
}

import Foundation

/// One Subsonic API call and the value its successful response carries.
public struct SubsonicRequest<Response: Decodable & Sendable>: Sendable {
    public let method: String
    public let parameters: [URLQueryItem]
    /// Where the value sits inside `subsonic-response`, for example `["albumList2", "album"]`.
    /// Empty means the response object itself (as for `ping`).
    public let elementPath: [String]

    public init(method: String, parameters: [URLQueryItem] = [], elementPath: [String] = []) {
        self.method = method
        self.parameters = parameters
        self.elementPath = elementPath
    }

    /// Identifies this request's response in a local cache: method and parameters, never credentials.
    public var cacheKey: String {
        parameters.isEmpty ? method : method + "?" + SubsonicURLBuilder.query(parameters)
    }
}

/// Who the server says it is. Classic servers send only `version`.
public struct ServerInfo: Decodable, Sendable, Equatable {
    public let apiVersion: String
    public let type: String?
    public let serverVersion: String?
    public let isOpenSubsonic: Bool

    public init(apiVersion: String, type: String?, serverVersion: String?, isOpenSubsonic: Bool) {
        self.apiVersion = apiVersion
        self.type = type
        self.serverVersion = serverVersion
        self.isOpenSubsonic = isOpenSubsonic
    }

    private enum CodingKeys: String, CodingKey {
        case apiVersion = "version", type, serverVersion, isOpenSubsonic = "openSubsonic"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apiVersion = try container.decode(String.self, forKey: .apiVersion)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        serverVersion = try container.decodeIfPresent(String.self, forKey: .serverVersion)
        isOpenSubsonic = try container.decodeIfPresent(Bool.self, forKey: .isOpenSubsonic) ?? false
    }
}

/// A successful response with no element of interest (star, scrobble, createBookmark, ...).
public struct EmptyResponse: Decodable, Sendable, Equatable {
    public init() {}
    public init(from _: any Decoder) throws {}
}

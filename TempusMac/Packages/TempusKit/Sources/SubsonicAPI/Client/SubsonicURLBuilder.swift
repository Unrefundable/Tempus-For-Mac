import Foundation

/// Builds `<server>/rest/<method>?<auth>&<parameters>` URLs.
enum SubsonicURLBuilder {
    /// RFC 3986 unreserved characters. Everything else is percent-encoded, including `+`, which
    /// `URLComponents` would leave as-is and servers would read as a space.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    static func url(
        server: ServerAddress,
        auth: SubsonicAuth,
        method: String,
        parameters: [URLQueryItem]
    ) throws(SubsonicError) -> URL {
        guard !method.isEmpty, method.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw .invalidMethod
        }
        guard var components = URLComponents(url: server.url, resolvingAgainstBaseURL: false) else {
            throw .invalidServerAddress
        }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + "/rest/" + method
        components.percentEncodedQuery = query(auth.queryItems + parameters)
        guard let url = components.url else { throw .invalidServerAddress }
        return url
    }

    /// `name=value&...`, every name and value percent-encoded.
    static func query(_ items: [URLQueryItem]) -> String {
        items.map { encode($0.name) + "=" + encode($0.value ?? "") }.joined(separator: "&")
    }

    private static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}

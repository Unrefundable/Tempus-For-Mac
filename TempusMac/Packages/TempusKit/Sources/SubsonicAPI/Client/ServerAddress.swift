import Foundation

/// A validated server base URL: http or https, with a host, and nothing that would change
/// where credentials go (no user info, query or fragment). Scheme and host are lowercased and a
/// trailing slash dropped, so equal addresses compare equal. The server may live under a
/// sub-path, for example `https://example.com/navidrome`.
public struct ServerAddress: Sendable, Hashable {
    public let url: URL

    public init(_ text: String) throws(SubsonicError) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace),
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1 ... 65535).contains($0) }) ?? true
        else {
            throw .invalidServerAddress
        }
        components.scheme = scheme
        components.host = host
        if components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        guard let url = components.url else { throw .invalidServerAddress }
        self.url = url
    }

    /// True for plain `http`: credentials and headers travel unencrypted. Fine on a home LAN,
    /// worth a warning anywhere else.
    public var isCleartext: Bool {
        url.scheme == "http"
    }
}

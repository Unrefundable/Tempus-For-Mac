import Foundation

/// User-defined HTTP headers for a server, for example Cloudflare Access service tokens.
/// Ported from upstream `CustomHeaders.kt`: one `Name: Value` per line, blank lines and `#`
/// comments ignored. Headers are only ever sent to the server's own origin (see `SessionGuard`).
public struct CustomHeaders: Sendable, Hashable {
    public struct Field: Sendable, Hashable {
        public let name: String
        public let value: String
    }

    /// Valid headers in first-seen order; a repeated name keeps its place and takes the last value.
    public let fields: [Field]

    public static let none = Self(fields: [])

    private static let tokenCharacters =
        Set("!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    /// Upstream's list, plus headers that would break streaming, decoding or the connection.
    private static let forbiddenNames: Set = [
        "host", "content-length", "transfer-encoding", "connection",
        "range", "content-type", "accept-encoding", "upgrade", "te",
    ]

    private init(fields: [Field]) {
        self.fields = fields
    }

    public init(parsing raw: String) {
        let parsed = Self.lines(of: raw).compactMap(Self.field(from:))
        fields = parsed.reduce(into: [Field]()) { result, field in
            if let index = result.firstIndex(where: { $0.name.lowercased() == field.name.lowercased() }) {
                result[index] = field
            } else {
                result.append(field)
            }
        }
    }

    /// For APIs that take a dictionary, such as the audio player.
    public var dictionary: [String: String] {
        Dictionary(fields.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
    }

    /// 1-based numbers of lines that are neither blank, comments nor valid headers.
    public static func invalidLineNumbers(in raw: String) -> [Int] {
        lines(of: raw).enumerated().compactMap { index, line in
            isIgnorable(line) || field(from: line) != nil ? nil : index + 1
        }
    }

    /// RFC 7230 token names, not a forbidden hop-by-hop header, and printable ASCII or tab values.
    public static func isValid(name: String, value: String) -> Bool {
        !name.isEmpty
            && name.allSatisfy(tokenCharacters.contains)
            && !forbiddenNames.contains(name.lowercased())
            && value.unicodeScalars.allSatisfy { (0x20 ... 0x7E).contains($0.value) || $0 == "\t" }
    }

    private static func lines(of raw: String) -> [Substring] {
        raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    }

    private static func isIgnorable(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("#")
    }

    private static func field(from line: Substring) -> Field? {
        guard !isIgnorable(line) else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.firstIndex(of: ":"), colon > trimmed.startIndex else { return nil }
        let name = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
        let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return isValid(name: name, value: value) ? Field(name: name, value: value) : nil
    }
}

/// Header values may be proxy secrets, so descriptions show names only.
extension CustomHeaders: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "CustomHeaders(\(fields.map { "\($0.name): <redacted>" }.joined(separator: ", ")))"
    }

    public var debugDescription: String {
        description
    }
}

public extension ServerAddress {
    /// `scheme://host:port` with the port always written, for binding stored secrets to it.
    var origin: String {
        guard let origin = Origin(url: url) else { return url.absoluteString }
        let host = origin.host.contains(":") ? "[\(origin.host)]" : origin.host // IPv6 literals
        return "\(origin.scheme)://\(host):\(origin.port)"
    }

    /// True when `url` has this server's scheme, host and port (default ports made explicit).
    func isSameOrigin(as url: URL) -> Bool {
        guard let mine = Origin(url: self.url), let theirs = Origin(url: url) else { return false }
        return mine == theirs
    }
}

struct Origin: Equatable {
    let scheme: String
    let host: String
    let port: Int

    init?(scheme: String, host: String?, port: Int?) {
        let scheme = scheme.lowercased()
        guard ["http", "https"].contains(scheme), let host = host?.lowercased(), !host.isEmpty else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = port.flatMap { $0 > 0 ? $0 : nil } ?? (scheme == "https" ? 443 : 80)
    }

    init?(url: URL) {
        guard let scheme = url.scheme else { return nil }
        self.init(scheme: scheme, host: url.host(), port: url.port)
    }
}

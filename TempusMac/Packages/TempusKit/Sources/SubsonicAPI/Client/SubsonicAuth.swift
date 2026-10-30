import CryptoKit
import Foundation

/// How a request proves the user's identity to a Subsonic server.
public enum SubsonicCredential: Sendable, Equatable {
    /// `t` = MD5(password + salt) and `s` = salt. The password never leaves the device.
    case token(token: String, salt: String)
    /// `p` = password, for servers that do not accept token auth ("low security" upstream).
    case plaintext(password: String)

    /// Builds token credentials, salting with a fresh UUID like upstream Tempus.
    public static func tokenized(password: String, salt: String = UUID().uuidString) -> Self {
        // MD5 is mandated by the Subsonic token-auth protocol; it is not a choice made here.
        let digest = Insecure.MD5.hash(data: Data((password + salt).utf8))
        let token = digest.map { String(format: "%02x", $0) }.joined()
        return .token(token: token, salt: salt)
    }
}

/// Redacted, so credentials can't leak into logs through string interpolation.
extension SubsonicCredential: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        switch self {
        case .token: "token(<redacted>)"
        case .plaintext: "plaintext(<redacted>)"
        }
    }

    public var debugDescription: String {
        description
    }
}

/// The query parameters every Subsonic request carries.
public struct SubsonicAuth: Sendable, Equatable {
    public static let defaultAPIVersion = "1.15.0"
    public static let defaultClientName = "Tempus"

    public let username: String
    public let credential: SubsonicCredential
    public let apiVersion: String
    public let clientName: String

    public init(
        username: String,
        credential: SubsonicCredential,
        apiVersion: String = Self.defaultAPIVersion,
        clientName: String = Self.defaultClientName
    ) {
        self.username = username
        self.credential = credential
        self.apiVersion = apiVersion
        self.clientName = clientName
    }

    public var queryItems: [URLQueryItem] {
        [URLQueryItem(name: "u", value: username)]
            + credentialItems
            + [
                URLQueryItem(name: "v", value: apiVersion),
                URLQueryItem(name: "c", value: clientName),
                URLQueryItem(name: "f", value: "json"),
            ]
    }

    private var credentialItems: [URLQueryItem] {
        switch credential {
        case let .token(token, salt):
            [URLQueryItem(name: "t", value: token), URLQueryItem(name: "s", value: salt)]
        case let .plaintext(password):
            [URLQueryItem(name: "p", value: password)]
        }
    }
}

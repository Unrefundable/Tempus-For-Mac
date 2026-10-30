import Foundation

/// Everything that can go wrong talking to a Subsonic server.
public enum SubsonicError: Error, Sendable, Equatable {
    /// The address is blank, not http(s), has no usable host, or carries user info, a query or a fragment.
    case invalidServerAddress
    /// The API method name is not plain letters and digits.
    case invalidMethod
    /// The calling task was cancelled.
    case cancelled
    /// The request never got an HTTP response (offline, DNS, TLS, timeout...).
    case transport(URLError.Code)
    /// The server or a proxy answered with a non-2xx status.
    case httpStatus(Int)
    /// The server answered `status: failed`.
    case server(code: SubsonicErrorCode, message: String?)
    /// The body was not the Subsonic response we expected.
    case decoding(String)
}

public extension SubsonicError {
    /// The server does not implement this endpoint (HTTP 501), as Navidrome answers for podcasts.
    /// Hide the feature rather than reporting an error.
    var isNotImplemented: Bool {
        self == .httpStatus(501)
    }
}

/// A Subsonic or OpenSubsonic error code. Unknown codes are kept as-is.
public struct SubsonicErrorCode: RawRepresentable, Sendable, Hashable, Decodable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let generic = Self(rawValue: 0)
    public static let missingParameter = Self(rawValue: 10)
    public static let clientMustUpgrade = Self(rawValue: 20)
    public static let serverMustUpgrade = Self(rawValue: 30)
    public static let wrongCredentials = Self(rawValue: 40)
    public static let tokenAuthNotSupported = Self(rawValue: 41)
    public static let authMechanismNotSupported = Self(rawValue: 42)
    public static let conflictingAuthMechanisms = Self(rawValue: 43)
    public static let invalidAPIKey = Self(rawValue: 44)
    public static let notAuthorized = Self(rawValue: 50)
    public static let trialExpired = Self(rawValue: 60)
    public static let notFound = Self(rawValue: 70)
}

import Foundation
import SubsonicAPI

/// Plain explanations of what went wrong talking to a server, with the next thing to try.
public extension SubsonicError {
    var userMessage: String {
        switch self {
        case .invalidServerAddress:
            "Enter an address that starts with http:// or https://."
        case .invalidMethod, .cancelled:
            "The request couldn't be sent."
        case let .server(code, message):
            Self.message(forServerCode: code, message: message)
        case let .httpStatus(status):
            Self.message(forHTTPStatus: status)
        case .decoding:
            Self.notSubsonic
        case let .transport(code):
            Self.message(forTransport: code)
        }
    }
}

extension SubsonicError {
    /// Server-supplied text is cut to this length before it is shown.
    static let maxShownServerMessage = 200

    /// A Subsonic server answered (with an error), not just something speaking HTTP.
    var isSubsonicAnswer: Bool {
        if case .server = self {
            true
        } else {
            false
        }
    }

    /// The server answered: it is reachable, whatever it thought of the request.
    var isAnswerFromServer: Bool {
        switch self {
        case .server: true
        case let .httpStatus(status): status != 404 && status < 500
        default: false
        }
    }

    private static let notSubsonic =
        "This address doesn't look like a Subsonic server. Check it, including any path such as /navidrome."

    private static func message(forServerCode code: SubsonicErrorCode, message: String?) -> String {
        switch code {
        case .wrongCredentials:
            return "Wrong username or password."
        case .tokenAuthNotSupported, .authMechanismNotSupported:
            return "This server doesn't accept secure sign-in. Turn on Plaintext password and try again."
        case .clientMustUpgrade:
            return "This server needs a newer Subsonic API than Tempus speaks."
        case .serverMustUpgrade:
            return "This server is too old for Tempus. Update the server and try again."
        case .notAuthorized:
            return "This account isn't allowed to do that."
        default:
            guard let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "The server reported an error (code \(code.rawValue))."
            }
            return "The server reported an error: \(shown(message))"
        }
    }

    /// Server text without control characters or line breaks, collapsed and shortened, so a
    /// hostile server can't lay out a convincing message of its own.
    private static func shown(_ message: String) -> String {
        let words = message.unicodeScalars
            .map {
                CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : Character($0)
            }
        return String(String(words).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .prefix(maxShownServerMessage))
    }

    private static func message(forHTTPStatus status: Int) -> String {
        switch status {
        case 401, 403:
            "The server or a proxy in front of it refused the request (HTTP \(status)). "
                + "If it sits behind an access proxy, add the custom headers it needs."
        case 404:
            notSubsonic
        case 500 ... 599:
            "The server had a problem (HTTP \(status)). Try again later."
        default:
            "The server answered with HTTP \(status)."
        }
    }

    private static func message(forTransport code: URLError.Code) -> String {
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            "You're offline. Check your network connection."
        case .cannotFindHost, .dnsLookupFailed:
            "Couldn't find the server. Check the address."
        case .cannotConnectToHost:
            "The server isn't answering at this address."
        case .timedOut:
            "The server took too long to answer."
        case .appTransportSecurityRequiresSecureConnection:
            "macOS only allows unencrypted http on the local network. Use https for this address."
        case .clientCertificateRequired, .clientCertificateRejected:
            "The server wants a client certificate. Add one under Client certificate (mTLS)."
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .secureConnectionFailed:
            "The server's certificate isn't trusted, so the connection was refused."
        default:
            "Couldn't reach the server (error \(code.rawValue))."
        }
    }
}

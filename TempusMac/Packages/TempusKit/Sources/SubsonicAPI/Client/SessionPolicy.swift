import Foundation

/// A TLS client identity for servers that require mutual TLS.
/// `SecIdentity` and `SecCertificate` are immutable Core Foundation objects, safe to share.
public struct ClientCertificate: @unchecked Sendable {
    public let identity: SecIdentity
    public let chain: [SecCertificate]

    public init(identity: SecIdentity, chain: [SecCertificate] = []) {
        self.identity = identity
        self.chain = chain
    }

    /// True for a client-certificate challenge from the server's own scheme, host and port.
    /// Anyone else asking (a redirect target, another host) must not learn the identity.
    static func isRequested(by space: URLProtectionSpace, from server: ServerAddress) -> Bool {
        guard space.authenticationMethod == NSURLAuthenticationMethodClientCertificate,
              let scheme = space.protocol,
              let challenger = Origin(scheme: scheme, host: space.host, port: space.port),
              let mine = Origin(url: server.url)
        else { return false }
        return challenger == mine
    }

    /// Answers the server's own client-certificate challenge when there is a certificate;
    /// everything else (including server trust) gets the system's default handling.
    static func response(
        to space: URLProtectionSpace,
        certificate: ClientCertificate?,
        server: ServerAddress
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let certificate, isRequested(by: space, from: server) else {
            return (.performDefaultHandling, nil)
        }
        return (
            .useCredential,
            URLCredential(identity: certificate.identity, certificates: certificate.chain, persistence: .forSession)
        )
    }
}

/// Upstream checks every redirect hop: custom headers must never follow a redirect off the server.
/// A redirect that leaves it keeps only headers that can't carry secrets, whatever the others are
/// called, so a header set by anyone (or a policy that is missing) fails closed.
enum RedirectPolicy {
    static let headersSafeOffOrigin: Set = [
        "accept", "accept-encoding", "accept-language", "icy-metadata", "if-range", "range", "user-agent",
    ]

    /// - Parameter server: nil when the origin is unknown; every redirect then counts as leaving it.
    static func request(following request: URLRequest, server: ServerAddress?) -> URLRequest {
        if let server, let url = request.url, server.isSameOrigin(as: url) {
            return request
        }
        var stripped = request
        for name in (request.allHTTPHeaderFields ?? [:]).keys where !headersSafeOffOrigin.contains(name.lowercased()) {
            stripped.setValue(nil, forHTTPHeaderField: name)
        }
        return stripped
    }
}

/// The rules `SubsonicClient` applies to its own requests, for media fetched outside it (the audio
/// player): custom headers only on the server's origin, stripped on redirects that leave it, and the
/// client certificate only for the server's own challenge.
public struct MediaRequestPolicy: Sendable {
    let server: ServerAddress
    let headers: CustomHeaders
    let certificate: ClientCertificate?

    /// The custom headers to send with `url`: all of them on the server's origin, none elsewhere.
    public func headers(for url: URL) -> [String: String] {
        server.isSameOrigin(as: url) ? headers.dictionary : [:]
    }

    /// The request to send when following a redirect.
    public func request(followingRedirectTo request: URLRequest) -> URLRequest {
        RedirectPolicy.request(following: request, server: server)
    }

    /// For a redirect when no server's policy applies: only the safe headers follow it.
    public static func requestWithoutPolicy(followingRedirectTo request: URLRequest) -> URLRequest {
        RedirectPolicy.request(following: request, server: nil)
    }

    /// The credential for a client-certificate challenge, or nil for default handling.
    public func credential(for space: URLProtectionSpace) -> URLCredential? {
        let (disposition, credential) = ClientCertificate.response(to: space, certificate: certificate, server: server)
        return disposition == .useCredential ? credential : nil
    }
}

/// Per-task URLSession delegate applying the redirect and client-certificate rules.
final class SessionGuard: NSObject, URLSessionTaskDelegate, Sendable {
    private let server: ServerAddress
    private let certificate: ClientCertificate?

    init(server: ServerAddress, certificate: ClientCertificate?) {
        self.server = server
        self.certificate = certificate
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        RedirectPolicy.request(following: request, server: server)
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        ClientCertificate.response(to: challenge.protectionSpace, certificate: certificate, server: server)
    }
}

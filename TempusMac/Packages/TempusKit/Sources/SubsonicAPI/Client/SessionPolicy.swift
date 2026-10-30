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
enum RedirectPolicy {
    static func request(following request: URLRequest, server: ServerAddress, headerNames: [String]) -> URLRequest {
        guard let url = request.url, !server.isSameOrigin(as: url) else { return request }
        var stripped = request
        for name in headerNames {
            stripped.setValue(nil, forHTTPHeaderField: name)
        }
        return stripped
    }
}

/// Per-task URLSession delegate applying the redirect and client-certificate rules.
final class SessionGuard: NSObject, URLSessionTaskDelegate, Sendable {
    private let server: ServerAddress
    private let headerNames: [String]
    private let certificate: ClientCertificate?

    init(server: ServerAddress, headerNames: [String], certificate: ClientCertificate?) {
        self.server = server
        self.headerNames = headerNames
        self.certificate = certificate
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        RedirectPolicy.request(following: request, server: server, headerNames: headerNames)
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        ClientCertificate.response(to: challenge.protectionSpace, certificate: certificate, server: server)
    }
}

import Foundation
import os

/// Sends HTTP requests. `URLSessionTransport` in the app, a stub in tests.
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// The production transport. Not public: every instance carries a `SessionGuard`, so header
/// scoping and client-certificate rules cannot be bypassed by accident.
struct URLSessionTransport: HTTPTransport {
    /// Request URLs carry credentials, so nothing is cached on disk and no cookies are kept.
    /// The resource timeout bounds the whole response, so a server cannot trickle bytes forever.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }()

    private let session: URLSession
    private let policy: SessionGuard

    init(session: URLSession = Self.session, policy: SessionGuard) {
        self.session = session
        self.policy = policy
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request, delegate: policy)
    }
}

/// Talks to one Subsonic server with one set of credentials.
public struct SubsonicClient: Sendable {
    public static let defaultTimeout: TimeInterval = 30
    /// Server-supplied text is shortened before it reaches errors and the UI.
    static let maxMessageLength = 500

    public let server: ServerAddress
    public let auth: SubsonicAuth
    public let headers: CustomHeaders
    /// The same header, redirect and certificate rules, for media the player fetches itself.
    public let mediaRequestPolicy: MediaRequestPolicy
    private let timeout: TimeInterval
    private let transport: any HTTPTransport

    private static let logger = Logger(subsystem: "io.github.unrefundable.TempusMac", category: "SubsonicClient")

    /// - Parameter transport: nil uses an ephemeral session that keeps custom headers off other
    ///   origins on redirect and presents `clientCertificate` only to this server.
    public init(
        server: ServerAddress,
        auth: SubsonicAuth,
        headers: CustomHeaders = .none,
        clientCertificate: ClientCertificate? = nil,
        timeout: TimeInterval = defaultTimeout,
        transport: (any HTTPTransport)? = nil
    ) {
        self.server = server
        self.auth = auth
        self.headers = headers
        mediaRequestPolicy = MediaRequestPolicy(server: server, headers: headers, certificate: clientCertificate)
        self.timeout = timeout
        self.transport = transport ?? URLSessionTransport(
            policy: SessionGuard(
                server: server,
                certificate: clientCertificate
            )
        )
    }

    /// The custom headers to send with `url`: all of them on this server's origin, none elsewhere.
    /// Use it for media requests made outside this client (player, image loader).
    public func headers(for url: URL) -> [String: String] {
        mediaRequestPolicy.headers(for: url)
    }

    /// The full URL for a request, credentials included. Treat it as a secret.
    public func url(for request: SubsonicRequest<some Any>) throws(SubsonicError) -> URL {
        try SubsonicURLBuilder.url(server: server, auth: auth, method: request.method, parameters: request.parameters)
    }

    public func send<Response>(_ request: SubsonicRequest<Response>) async throws(SubsonicError) -> Response {
        try await fetch(request).value
    }

    /// Like `send`, but also returns the raw response body so it can be cached and later read
    /// back with `decode(_:from:)`. Only successful responses are returned.
    public func fetch<Response>(
        _ request: SubsonicRequest<Response>
    ) async throws(SubsonicError) -> (value: Response, data: Data) {
        var urlRequest = try URLRequest(url: url(for: request), timeoutInterval: timeout)
        for field in headers.fields {
            urlRequest.setValue(field.value, forHTTPHeaderField: field.name)
        }
        let (data, response) = try await perform(urlRequest, method: request.method)

        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            // Some servers explain the failure in a Subsonic body; prefer their code and message.
            let envelope = try? JSONDecoder().decode(ResponseEnvelope<EmptyResponse>.self, from: data)
            if case let .failed(code, message) = envelope?.body {
                throw Self.serverError(code: code, message: message, method: request.method)
            }
            Self.logger.error("\(request.method, privacy: .public) failed with HTTP \(http.statusCode)")
            throw .httpStatus(http.statusCode)
        }

        return try (Self.decode(request, from: data), data)
    }

    /// Reads a response body, fresh or cached, through the same lenient decoding as `send`.
    public static func decode<Response>(
        _ request: SubsonicRequest<Response>,
        from data: Data
    ) throws(SubsonicError) -> Response {
        let decoder = JSONDecoder()
        decoder.userInfo[.subsonicElementPath] = request.elementPath
        let body: ResponseBody<Response>
        do {
            body = try decoder.decode(ResponseEnvelope<Response>.self, from: data).body
        } catch {
            logger.error("\(request.method, privacy: .public) returned an unreadable response: \(error)")
            throw .decoding(String(String(describing: error).prefix(maxMessageLength)))
        }

        switch body {
        case let .ok(payload):
            return payload
        case let .failed(code, message):
            throw serverError(code: code, message: message, method: request.method)
        }
    }

    private static func serverError(code: SubsonicErrorCode, message: String?, method: String) -> SubsonicError {
        logger.error("\(method, privacy: .public) failed with Subsonic error \(code.rawValue)")
        return .server(code: code, message: message.map { String($0.prefix(maxMessageLength)) })
    }

    private func perform(_ request: URLRequest, method: String) async throws(SubsonicError) -> (Data, URLResponse) {
        do {
            return try await transport.data(for: request)
        } catch is CancellationError {
            throw .cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw .cancelled
        } catch let error as URLError {
            Self.logger.error("\(method, privacy: .public) transport error \(error.code.rawValue)")
            throw .transport(error.code)
        } catch {
            Self.logger.error("\(method, privacy: .public) transport error: \(error)")
            throw .transport(.unknown)
        }
    }
}

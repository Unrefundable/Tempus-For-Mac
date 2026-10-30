import Foundation
@testable import SubsonicAPI
import Testing

/// Answers every request with a canned body or error and remembers the last request.
actor StubTransport: HTTPTransport {
    private let body: String
    private let statusCode: Int
    private let error: URLError?
    private(set) var lastRequest: URLRequest?

    init(body: String = "", statusCode: Int = 200, error: URLError? = nil) {
        self.body = body
        self.statusCode = statusCode
        self.error = error
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        if let error {
            throw error
        }
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        ))
        return (Data(body.utf8), response)
    }
}

private struct AlbumStub: Decodable, Sendable {
    struct Album: Decodable, Sendable {
        let id: String
    }

    let album: Album
}

private extension SubsonicError? {
    var isDecoding: Bool {
        guard case .decoding = self else { return false }
        return true
    }
}

private func client(_ transport: StubTransport) throws -> SubsonicClient {
    try SubsonicClient(
        server: ServerAddress("https://music.example.com"),
        auth: SubsonicAuth(username: "alice", credential: .token(token: "tok", salt: "salt")),
        transport: transport
    )
}

@Suite("Subsonic client envelope and errors")
struct ClientTests {
    @Test("Ping reports server identity from an OpenSubsonic server")
    func pingOpenSubsonic() async throws {
        let transport = StubTransport(body: #"""
        {"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome",
        "serverVersion":"0.53.3","openSubsonic":true}}
        """#)

        let info = try await client(transport).send(.ping)

        #expect(info == ServerInfo(
            apiVersion: "1.16.1",
            type: "navidrome",
            serverVersion: "0.53.3",
            isOpenSubsonic: true
        ))
    }

    @Test("Ping works against a classic server without OpenSubsonic fields")
    func pingClassic() async throws {
        let transport = StubTransport(body: #"{"subsonic-response":{"status":"ok","version":"1.15.0"}}"#)

        let info = try await client(transport).send(.ping)

        #expect(info == ServerInfo(apiVersion: "1.15.0", type: nil, serverVersion: nil, isOpenSubsonic: false))
    }

    @Test("Requests are GETs to the method URL")
    func requestShape() async throws {
        let transport =
            StubTransport(body: #"{"subsonic-response":{"status":"ok","version":"1.15.0","album":{"id":"al-1"}}}"#)
        let request = SubsonicRequest<AlbumStub>(
            method: "getAlbum",
            parameters: [URLQueryItem(name: "id", value: "al-1")]
        )

        let album = try await client(transport).send(request)
        let sent = try #require(await transport.lastRequest)

        #expect(album.album.id == "al-1")
        #expect(sent.httpMethod == "GET")
        #expect(sent.url?.path() == "/rest/getAlbum")
        #expect(sent.url?.query()?.hasSuffix("id=al-1") == true)
    }

    @Test("A non-2xx status with a Subsonic error body reports the server's own error")
    func errorStatusWithSubsonicBody() async throws {
        let body = #"""
        {"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":0,"message":"Not implemented"}}}
        """#
        let transport = StubTransport(body: body, statusCode: 501)

        await #expect(throws: SubsonicError.server(code: .generic, message: "Not implemented")) {
            try await client(transport).send(.ping)
        }
    }

    @Test("A bare 501 means the server does not implement the endpoint (Navidrome podcasts)")
    func notImplemented() async throws {
        let transport = StubTransport(body: "Not Implemented", statusCode: 501)

        let error = await #expect(throws: SubsonicError.httpStatus(501)) { try await client(transport).send(.ping) }

        #expect(error?.isNotImplemented == true)
        #expect(SubsonicError.httpStatus(502).isNotImplemented == false)
    }

    @Test("A failed status becomes a server error with its code and message")
    func serverError() async throws {
        let transport = StubTransport(body: #"""
        {"subsonic-response":{"status":"failed","version":"1.15.0",
        "error":{"code":40,"message":"Wrong username or password"}}}
        """#)

        await #expect(throws: SubsonicError.server(code: .wrongCredentials, message: "Wrong username or password")) {
            try await client(transport).send(.ping)
        }
    }

    @Test("A failed status without an error object is a generic server error")
    func serverErrorWithoutDetails() async throws {
        let transport = StubTransport(body: #"{"subsonic-response":{"status":"failed","version":"1.15.0"}}"#)

        await #expect(throws: SubsonicError.server(code: .generic, message: nil)) {
            try await client(transport).send(.ping)
        }
    }

    @Test("A non-2xx HTTP status is reported as such")
    func httpStatus() async throws {
        let transport = StubTransport(body: "<html>Bad gateway</html>", statusCode: 502)

        await #expect(throws: SubsonicError.httpStatus(502)) { try await client(transport).send(.ping) }
    }

    @Test("A body that is not a Subsonic response is a decoding error")
    func notSubsonic() async throws {
        let transport = StubTransport(body: "<html>Login</html>")

        let error = await #expect(throws: SubsonicError.self) { try await client(transport).send(.ping) }

        #expect(error.isDecoding)
    }

    @Test("An ok response missing the expected element is a decoding error")
    func missingPayload() async throws {
        let transport = StubTransport(body: #"{"subsonic-response":{"status":"ok","version":"1.15.0"}}"#)
        let request = SubsonicRequest<AlbumStub>(method: "getAlbum", parameters: [])

        let error = await #expect(throws: SubsonicError.self) { try await client(transport).send(request) }

        #expect(error.isDecoding)
    }

    @Test("Network failures keep their URLError code")
    func transportError() async throws {
        let transport = StubTransport(error: URLError(.notConnectedToInternet))

        await #expect(throws: SubsonicError.transport(.notConnectedToInternet)) {
            try await client(transport).send(.ping)
        }
    }

    @Test("Cancellation is reported as cancelled, not as a network failure", arguments: [
        URLError(.cancelled),
    ])
    func cancellation(error: URLError) async throws {
        let transport = StubTransport(error: error)

        await #expect(throws: SubsonicError.cancelled) { try await client(transport).send(.ping) }
    }

    @Test("Server error messages are cut to 500 characters")
    func longMessagesTruncated() async throws {
        let long = String(repeating: "x", count: 5000)
        let transport = StubTransport(body: #"""
        {"subsonic-response":{"status":"failed","version":"1.15.0","error":{"code":0,"message":"\#(long)"}}}
        """#)

        let error = await #expect(throws: SubsonicError.self) { try await client(transport).send(.ping) }

        guard case let .server(_, message) = error else { Issue.record("Expected .server"); return }
        #expect(message?.count == 500)
    }

    @Test("Unknown server error codes are preserved")
    func unknownErrorCode() async throws {
        let transport = StubTransport(body: #"""
        {"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":44,"message":"Invalid API key"}}}
        """#)

        await #expect(throws: SubsonicError.server(code: SubsonicErrorCode(rawValue: 44), message: "Invalid API key")) {
            try await client(transport).send(.ping)
        }
    }
}

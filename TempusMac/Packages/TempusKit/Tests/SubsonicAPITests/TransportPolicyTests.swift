import Foundation
@testable import SubsonicAPI
import Testing

@Suite("Headers on requests, media URLs and redirects")
struct TransportPolicyTests {
    let headers = CustomHeaders(parsing: "CF-Access-Client-Id: abc\nCF-Access-Client-Secret: xyz")

    private func client(_ transport: StubTransport) throws -> SubsonicClient {
        try SubsonicClient(
            server: ServerAddress("https://music.example.com"),
            auth: SubsonicAuth(username: "alice", credential: .token(token: "t", salt: "s")),
            headers: headers,
            transport: transport
        )
    }

    @Test("API requests carry the server's custom headers")
    func apiRequestsCarryHeaders() async throws {
        let transport = StubTransport(body: #"{"subsonic-response":{"status":"ok","version":"1.15.0"}}"#)

        _ = try await client(transport).send(.ping)
        let sent = try #require(await transport.lastRequest)

        #expect(sent.value(forHTTPHeaderField: "CF-Access-Client-Id") == "abc")
        #expect(sent.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "xyz")
    }

    @Test("Media URLs on the server get the headers; other hosts get none")
    func mediaHeadersAreScoped() throws {
        let client = try client(StubTransport())

        #expect(try client.headers(for: client.streamURL(id: "s1")) == [
            "CF-Access-Client-Id": "abc", "CF-Access-Client-Secret": "xyz",
        ])
        #expect(try client.headers(for: #require(URL(string: "https://radio.example.org/live"))).isEmpty)
    }

    @Test("A redirect within the server keeps the headers")
    func sameOriginRedirect() throws {
        let server = try ServerAddress("https://music.example.com")
        var request = try URLRequest(url: #require(URL(string: "https://music.example.com/rest/stream2")))
        request.setValue("abc", forHTTPHeaderField: "CF-Access-Client-Id")

        let followed = RedirectPolicy.request(following: request, server: server, headerNames: ["CF-Access-Client-Id"])

        #expect(followed.value(forHTTPHeaderField: "CF-Access-Client-Id") == "abc")
    }

    @Test("A redirect to another origin drops the headers but keeps others")
    func crossOriginRedirect() throws {
        let server = try ServerAddress("https://music.example.com")
        var request = try URLRequest(url: #require(URL(string: "https://cdn.example.net/file.flac")))
        request.setValue("abc", forHTTPHeaderField: "CF-Access-Client-Id")
        request.setValue("bytes=0-", forHTTPHeaderField: "Range")

        let followed = RedirectPolicy.request(following: request, server: server, headerNames: ["cf-access-client-id"])

        #expect(followed.value(forHTTPHeaderField: "CF-Access-Client-Id") == nil)
        #expect(followed.value(forHTTPHeaderField: "Range") == "bytes=0-")
    }

    @Test("The client certificate goes only to the server's own host and port", arguments: [
        (NSURLAuthenticationMethodClientCertificate, "music.example.com", 443, true),
        (NSURLAuthenticationMethodClientCertificate, "MUSIC.example.com", 443, true),
        (NSURLAuthenticationMethodClientCertificate, "cdn.example.net", 443, false),
        (NSURLAuthenticationMethodClientCertificate, "music.example.com", 8443, false),
        (NSURLAuthenticationMethodServerTrust, "music.example.com", 443, false),
    ])
    func certificateScope(method: String, host: String, port: Int, expected: Bool) throws {
        let server = try ServerAddress("https://music.example.com")
        let space = URLProtectionSpace(
            host: host,
            port: port,
            protocol: "https",
            realm: nil,
            authenticationMethod: method
        )

        #expect(ClientCertificate.isRequested(by: space, from: server) == expected)
    }

    @Test("Only client-certificate challenges are answered, and only with a certificate", arguments: [
        (NSURLAuthenticationMethodServerTrust, false),
        (NSURLAuthenticationMethodHTTPBasic, false),
        (NSURLAuthenticationMethodClientCertificate, false),
    ])
    func challengeWithoutCertificate(method: String, _: Bool) throws {
        let space = URLProtectionSpace(
            host: "music.example.com", port: 443, protocol: "https", realm: nil, authenticationMethod: method
        )

        let server = try ServerAddress("https://music.example.com")

        let (disposition, credential) = ClientCertificate.response(to: space, certificate: nil, server: server)

        #expect(disposition == .performDefaultHandling)
        #expect(credential == nil)
    }
}

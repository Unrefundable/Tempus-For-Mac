import Foundation
@testable import SubsonicAPI
import Testing

/// Ported from upstream `CustomHeadersTest.kt`.
@Suite("Custom HTTP headers")
struct CustomHeadersTests {
    private func pairs(_ headers: CustomHeaders) -> [String] {
        headers.fields.map { "\($0.name)=\($0.value)" }
    }

    @Test("Reads Name: Value lines, skipping blanks and comments, trimming around the value")
    func readsLines() {
        let headers = CustomHeaders(parsing: "CF-Access-Client-Id: abc\n\n# comment\nX-Token:  s3cr:et  \n")

        #expect(pairs(headers) == ["CF-Access-Client-Id=abc", "X-Token=s3cr:et"])
    }

    @Test("Keeps first-seen order; the last duplicate's value wins")
    func duplicates() {
        #expect(pairs(CustomHeaders(parsing: "B: 1\nA: 2\nB: 3")) == ["B=3", "A=2"])
    }

    @Test("Handles CRLF line endings and empty values")
    func crlfAndEmpty() {
        #expect(pairs(CustomHeaders(parsing: "X-A: 1\r\nX-Empty:\r\n")) == ["X-A=1", "X-Empty="])
    }

    @Test("Blank input has no headers")
    func blank() {
        #expect(CustomHeaders(parsing: "").fields.isEmpty)
        #expect(CustomHeaders(parsing: "  \n ").fields.isEmpty)
    }

    @Test("Skips lines without a name, invalid names and forbidden headers")
    func skipsInvalid() {
        let raw = "no colon\n: novalue-name\nBad Name: x\nHost: evil\ncontent-length: 1\n"
            + "Transfer-Encoding: chunked\nCONNECTION: close\nOk: 1"

        #expect(pairs(CustomHeaders(parsing: raw)) == ["Ok=1"])
    }

    @Test("Also refuses headers that would break streaming or encoding", arguments: [
        "Range: bytes=0-", "Content-Type: text/plain", "Accept-Encoding: br", "Upgrade: h2c", "TE: trailers",
    ])
    func refusesTransportHeaders(line: String) {
        #expect(CustomHeaders(parsing: line).fields.isEmpty)
    }

    @Test("Descriptions never reveal header values")
    func redactedDescription() {
        let headers = CustomHeaders(parsing: "CF-Access-Client-Secret: hunter2")

        #expect(!String(describing: headers).contains("hunter2"))
        #expect(!String(reflecting: headers).contains("hunter2"))
        #expect(String(describing: headers).contains("CF-Access-Client-Secret"))
    }

    @Test("Rejects control and non-ASCII values but allows tabs")
    func valueCharacters() {
        #expect(CustomHeaders(parsing: "X-A: a\u{0000}b").fields.isEmpty)
        #expect(CustomHeaders(parsing: "X-A: caf\u{00e9}").fields.isEmpty)
        #expect(CustomHeaders(parsing: "X-A: a\u{007f}b").fields.isEmpty)
        #expect(pairs(CustomHeaders(parsing: "X-A: a\tb")) == ["X-A=a\tb"])
    }

    @Test("Reports 1-based numbers of invalid lines, ignoring blanks and comments")
    func invalidLineNumbers() {
        #expect(CustomHeaders.invalidLineNumbers(in: "Ok: 1\nbroken\n\n# fine\nHost: x") == [2, 5])
        #expect(CustomHeaders.invalidLineNumbers(in: "").isEmpty)
        #expect(CustomHeaders.invalidLineNumbers(in: "X-A: 1\n# c\n").isEmpty)
    }

    @Test("isValid applies the same rules as parsing")
    func isValid() {
        #expect(CustomHeaders.isValid(name: "Authorization", value: "Basic dTpw"))
        #expect(CustomHeaders.isValid(name: "X-Empty", value: ""))
        #expect(!CustomHeaders.isValid(name: "Bad Name", value: "x"))
        #expect(!CustomHeaders.isValid(name: "Host", value: "evil"))
        #expect(!CustomHeaders.isValid(name: "X-A", value: "a\nb"))
    }

    @Test("Origin matching compares scheme, host and port only", arguments: [
        ("https://music.example.com/rest/stream?id=1", true),
        ("https://music.example.com:443/rest/ping", true),
        ("HTTPS://MUSIC.example.com/rest", true),
        ("http://music.example.com/rest/ping", false),
        ("https://music.example.com:8443/rest", false),
        ("https://radio.example.org/stream", false),
        ("https://evil.music.example.com/rest", false),
        ("https://music.example.com.evil.org/rest", false),
        ("content://media/1", false),
    ])
    func origin(url: String, expected: Bool) throws {
        let server = try ServerAddress("https://music.example.com")

        #expect(try server.isSameOrigin(as: #require(URL(string: url))) == expected)
    }

    @Test("Origins are written with an explicit port, for binding stored secrets", arguments: [
        ("https://music.example.com/navidrome", "https://music.example.com:443"),
        ("http://192.168.1.5:4533", "http://192.168.1.5:4533"),
        ("http://music.example.com", "http://music.example.com:80"),
        ("http://[::1]:4533", "http://[::1]:4533"),
    ])
    func originText(address: String, expected: String) throws {
        #expect(try ServerAddress(address).origin == expected)
    }

    @Test("Origin matching with explicit ports and sub-paths")
    func originPortsAndPaths() throws {
        let lan = try ServerAddress("http://192.168.1.5:4533")
        let subPath = try ServerAddress("https://example.com/navidrome/")

        #expect(try lan.isSameOrigin(as: #require(URL(string: "http://192.168.1.5:4533/rest/ping"))))
        #expect(try !lan.isSameOrigin(as: #require(URL(string: "http://192.168.1.5/rest/ping"))))
        #expect(try subPath.isSameOrigin(as: #require(URL(string: "https://example.com/navidrome/rest/ping"))))
    }
}

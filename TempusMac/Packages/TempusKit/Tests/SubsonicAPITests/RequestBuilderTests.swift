import Foundation
@testable import SubsonicAPI
import Testing

@Suite("Server addresses and request URLs")
struct RequestBuilderTests {
    let auth = SubsonicAuth(username: "alice", credential: .token(token: "tok", salt: "salt"))

    @Test("Valid addresses are trimmed and accepted", arguments: [
        ("  https://music.example.com  ", "https://music.example.com"),
        ("http://192.168.1.10:4533/", "http://192.168.1.10:4533"),
        ("https://example.com/navidrome", "https://example.com/navidrome"),
    ])
    func validAddresses(input: String, expected: String) throws {
        #expect(try ServerAddress(input).url.absoluteString == expected)
    }

    @Test("Unusable addresses are rejected", arguments: [
        "",
        "   ",
        "music.example.com",
        "ftp://music.example.com",
        "https://",
        "http://navi.example com",
        "https://user:pw@music.example.com",
        "https://music.example.com.evil.org@music.example.com",
        "https://music.example.com/?a=1",
        "https://music.example.com/#top",
        "http://music.example.com:0",
    ])
    func invalidAddresses(input: String) {
        #expect(throws: SubsonicError.invalidServerAddress) { try ServerAddress(input) }
    }

    @Test("Scheme and host are lowercased so equal addresses compare equal")
    func normalizesCase() throws {
        let address = try ServerAddress("HTTPS://Music.Example.COM/Navidrome")

        #expect(address.url.absoluteString == "https://music.example.com/Navidrome")
        #expect(try address == ServerAddress("https://music.example.com/Navidrome"))
    }

    @Test("Plain http is flagged as cleartext")
    func cleartext() throws {
        #expect(try ServerAddress("http://192.168.1.10:4533").isCleartext)
        #expect(try !ServerAddress("https://music.example.com").isCleartext)
    }

    @Test("Method names must be plain letters and digits", arguments: ["get Album", "../ping", "ping?x=1", ""])
    func rejectsUnsafeMethods(method: String) throws {
        let server = try ServerAddress("https://music.example.com")

        #expect(throws: SubsonicError.invalidMethod) {
            try SubsonicURLBuilder.url(server: server, auth: auth, method: method, parameters: [])
        }
    }

    @Test("URL is base + /rest/ + method, auth parameters first, then request parameters")
    func buildsURL() throws {
        let url = try SubsonicURLBuilder.url(
            server: ServerAddress("https://music.example.com"),
            auth: auth,
            method: "getAlbum",
            parameters: [URLQueryItem(name: "id", value: "al-1")]
        )

        #expect(url.absoluteString
            == "https://music.example.com/rest/getAlbum?u=alice&t=tok&s=salt&v=1.15.0&c=Tempus&f=json&id=al-1")
    }

    @Test("A server under a sub-path keeps it, with or without a trailing slash", arguments: [
        "https://example.com/navidrome",
        "https://example.com/navidrome/",
    ])
    func keepsSubPath(base: String) throws {
        let url = try SubsonicURLBuilder.url(server: ServerAddress(base), auth: auth, method: "ping", parameters: [])

        #expect(url.path() == "/navidrome/rest/ping")
    }

    @Test("Reserved and non-ASCII characters in values are percent-encoded, including +")
    func encodesValues() throws {
        let plaintext = SubsonicAuth(username: "bob smith", credential: .plaintext(password: "a+b&c=d é/?"))

        let url = try SubsonicURLBuilder.url(
            server: ServerAddress("https://music.example.com"),
            auth: plaintext,
            method: "ping",
            parameters: []
        )

        let query = try #require(url.query(percentEncoded: true))
        #expect(query.contains("u=bob%20smith"))
        #expect(query.contains("p=a%2Bb%26c%3Dd%20%C3%A9%2F%3F"))
    }

    @Test("Repeated parameters are all kept, in order")
    func repeatedParameters() throws {
        let url = try SubsonicURLBuilder.url(
            server: ServerAddress("https://music.example.com"),
            auth: auth,
            method: "star",
            parameters: [URLQueryItem(name: "id", value: "1"), URLQueryItem(name: "id", value: "2")]
        )

        #expect(url.query(percentEncoded: true)?.hasSuffix("&id=1&id=2") == true)
    }
}

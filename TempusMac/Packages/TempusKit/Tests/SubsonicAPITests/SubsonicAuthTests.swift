import Foundation
@testable import SubsonicAPI
import Testing

@Suite("Subsonic authentication parameters")
struct SubsonicAuthTests {
    @Test("Token is the lowercase MD5 hex of password followed by salt")
    func tokenIsMD5OfPasswordAndSalt() {
        // Example from the Subsonic API documentation.
        let credential = SubsonicCredential.tokenized(password: "sesame", salt: "c19b2d")

        #expect(credential == .token(token: "26719a1196d2a940705a59634eb18eab", salt: "c19b2d"))
    }

    @Test("Non-ASCII passwords are hashed as UTF-8")
    func nonASCIIPasswordIsHashedAsUTF8() {
        let credential = SubsonicCredential.tokenized(password: "pässwörd🎵", salt: "salt")

        #expect(credential == .token(token: "b62b92dce02b203785c4d093be9939a2", salt: "salt"))
    }

    @Test("Parameters keep a stable order: u, credential, v, c, f")
    func queryItemOrderIsStable() {
        let auth = SubsonicAuth(username: "alice", credential: .token(token: "abc", salt: "s1"))

        #expect(auth.queryItems.map(\.name) == ["u", "t", "s", "v", "c", "f"])
    }

    @Test("Descriptions never reveal secrets", arguments: [
        SubsonicCredential.plaintext(password: "hunter2"),
        SubsonicCredential.token(token: "hunter2", salt: "hunter2"),
    ])
    func descriptionsAreRedacted(credential: SubsonicCredential) {
        let auth = SubsonicAuth(username: "alice", credential: credential)

        #expect(!String(describing: credential).contains("hunter2"))
        #expect(!String(reflecting: credential).contains("hunter2"))
        #expect(!String(describing: auth).contains("hunter2"))
    }

    @Test("Generated salts differ between calls")
    func generatedSaltsAreUnique() {
        let first = SubsonicCredential.tokenized(password: "sesame")
        let second = SubsonicCredential.tokenized(password: "sesame")

        #expect(first != second)
    }

    @Test("Token auth sends u, t, s, v, c and f but never the password")
    func tokenQueryItems() {
        let auth = SubsonicAuth(
            username: "alice",
            credential: .token(token: "abc123", salt: "salt1")
        )

        let items = Dictionary(uniqueKeysWithValues: auth.queryItems.map { ($0.name, $0.value) })

        #expect(items == [
            "u": "alice",
            "t": "abc123",
            "s": "salt1",
            "v": "1.15.0",
            "c": "Tempus",
            "f": "json",
        ])
    }

    @Test("Plaintext auth sends p instead of t and s")
    func plaintextQueryItems() {
        let auth = SubsonicAuth(username: "alice", credential: .plaintext(password: "sesame"))

        let names = auth.queryItems.map(\.name)
        let password = auth.queryItems.first { $0.name == "p" }?.value

        #expect(password == "sesame")
        #expect(!names.contains("t"))
        #expect(!names.contains("s"))
    }

    @Test("Client name and API version can be overridden")
    func customClientAndVersion() {
        let auth = SubsonicAuth(
            username: "alice",
            credential: .plaintext(password: "x"),
            apiVersion: "1.16.1",
            clientName: "Tempus macOS"
        )

        let items = Dictionary(uniqueKeysWithValues: auth.queryItems.map { ($0.name, $0.value) })

        #expect(items["v"] == "1.16.1")
        #expect(items["c"] == "Tempus macOS")
    }
}

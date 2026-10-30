import Foundation
@testable import SubsonicAPI
import Testing

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func fixtureText(_ name: String) throws -> String {
    try #require(String(data: fixture(name), encoding: .utf8))
}

private func client(_ transport: StubTransport) throws -> SubsonicClient {
    try SubsonicClient(
        server: ServerAddress("https://music.example.com"),
        auth: SubsonicAuth(username: "alice", credential: .token(token: "t", salt: "s")),
        transport: transport
    )
}

@Suite("Support for caching responses and storing songs")
struct CachingSupportTests {
    @Test("Songs survive an encode/decode round trip, including dates, ids and ReplayGain")
    func songRoundTrip() async throws {
        let album = try await client(StubTransport(body: fixtureText("getAlbum")))
            .send(.album(id: "al-blue-train"))
        let original = try #require(album.songs.first)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let encoded = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(Song.self, from: encoded)

        #expect(decoded.id == original.id)
        #expect(decoded.title == original.title)
        #expect(decoded.albumArtist == original.albumArtist)
        #expect(decoded.replayGain == original.replayGain)
        #expect(decoded.bitrate == original.bitrate)
        let created = try #require(decoded.created)
        let originalCreated = try #require(original.created)
        #expect(abs(created.timeIntervalSince(originalCreated)) < 0.001)
        #expect(try encoder.encode(decoded) == encoded)
    }

    @Test("Numeric ids from classic servers are stored as strings")
    func numericIDsRoundTrip() async throws {
        let body = try fixtureText("getAlbum-classic")
        let song = try #require(try await client(StubTransport(body: body)).send(.album(id: "1042")).songs.first)

        let decoded = try JSONDecoder().decode(Song.self, from: JSONEncoder().encode(song))

        #expect(decoded.id == "99001")
        #expect(decoded.parentID == "1042")
        #expect(decoded.albumArtist == "Miles Davis")
    }

    @Test("Structured lyrics survive a round trip")
    func lyricsRoundTrip() async throws {
        let body = try fixtureText("getLyricsBySongId")
        let lyrics = try await client(StubTransport(body: body)).send(.lyrics(songID: "s1"))

        let decoded = try JSONDecoder().decode([StructuredLyrics].self, from: JSONEncoder().encode(lyrics))

        #expect(decoded == lyrics)
    }

    @Test("fetch returns the value and the raw body; decode reads the body back")
    func fetchAndDecode() async throws {
        let body = try fixtureText("getArtist")
        let client = try client(StubTransport(body: body))

        let (artist, data) = try await client.fetch(.artist(id: "ar-coltrane"))
        let reread = try SubsonicClient.decode(.artist(id: "ar-coltrane"), from: data)

        #expect(reread == artist)
        #expect(data == Data(body.utf8))
    }

    @Test("Decoding a stored failure body reports the server error")
    func decodeFailure() throws {
        let body = #"{"subsonic-response":{"status":"failed","version":"1.15.0","error":{"code":70,"message":"Gone"}}}"#

        #expect(throws: SubsonicError.server(code: .notFound, message: "Gone")) {
            try SubsonicClient.decode(.album(id: "x"), from: Data(body.utf8))
        }
    }

    @Test("Cache keys name the method and parameters but never credentials")
    func cacheKeys() {
        #expect(SubsonicRequest.albumList(.newest, size: 20).cacheKey == "getAlbumList2?type=newest&size=20&offset=0")
        #expect(SubsonicRequest.album(id: "a b").cacheKey == "getAlbum?id=a%20b")
        #expect(SubsonicRequest.playlists.cacheKey == "getPlaylists")
    }
}

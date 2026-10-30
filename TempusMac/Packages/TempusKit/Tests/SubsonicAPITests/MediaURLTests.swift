import Foundation
@testable import SubsonicAPI
import Testing

@Suite("Stream, download and cover-art URLs")
struct MediaURLTests {
    let client: SubsonicClient

    init() throws {
        client = try SubsonicClient(
            server: ServerAddress("https://music.example.com/navidrome"),
            auth: SubsonicAuth(username: "alice", credential: .token(token: "tok", salt: "salt")),
            transport: StubTransport()
        )
    }

    private func tail(_ url: URL) throws -> String {
        let query = try #require(url.query(percentEncoded: true))
        return String(query.dropFirst("u=alice&t=tok&s=salt&v=1.15.0&c=Tempus&f=json&".count))
    }

    @Test("Letting the server decide sends neither format nor bitrate")
    func serverDefault() throws {
        let url = try client.streamURL(id: "s1")

        #expect(url.path() == "/navidrome/rest/stream")
        #expect(try tail(url) == "id=s1")
    }

    @Test("Original quality asks for raw with no bitrate ceiling")
    func original() throws {
        #expect(try tail(client.streamURL(id: "s1", quality: .original)) == "maxBitRate=0&format=raw&id=s1")
    }

    @Test("Transcoding sends the format and ceiling")
    func transcoded() throws {
        let url = try client.streamURL(id: "s1", quality: .transcoded(format: "opus", maxBitrate: 128))

        #expect(try tail(url) == "maxBitRate=128&format=opus&id=s1")
    }

    @Test("A positive time offset is sent; zero is not")
    func timeOffset() throws {
        #expect(try tail(client.streamURL(id: "s1", timeOffset: 30)) == "timeOffset=30&id=s1")
        #expect(try tail(client.streamURL(id: "s1", timeOffset: 0)) == "id=s1")
    }

    @Test("Download URL")
    func download() throws {
        let url = try client.downloadURL(id: "s1")

        #expect(url.path() == "/navidrome/rest/download")
        #expect(try tail(url) == "id=s1")
    }

    @Test("Cover art with and without a size")
    func coverArt() throws {
        let sized = try client.coverArtURL(id: "al-1_0", size: 300)

        #expect(sized.path() == "/navidrome/rest/getCoverArt")
        #expect(try tail(sized) == "size=300&id=al-1_0")
        #expect(try tail(client.coverArtURL(id: "al-1_0")) == "id=al-1_0")
    }
}

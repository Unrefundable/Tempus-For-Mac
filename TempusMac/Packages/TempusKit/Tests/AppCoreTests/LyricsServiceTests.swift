@testable import AppCore
import Foundation
import Persistence
import SubsonicAPI
import Testing

struct LyricsServiceTests {
    static let synced = Data(#"""
    {"subsonic-response":{"status":"ok","version":"1.16.1","lyricsList":{"structuredLyrics":[
      {"lang":"eng","synced":true,"offset":0,"line":[{"start":0,"value":"One"},{"start":2000,"value":"Two"}]}
    ]}}}
    """#.utf8)
    static let plain = Data(#"""
    {"subsonic-response":{"status":"ok","version":"1.16.1","lyrics":{"artist":"A","title":"T","value":"Plain\nwords"}}}
    """#.utf8)

    func service(_ bodies: [String: Data], openSubsonic: Bool = true) async throws -> (LyricsService, AppDatabase) {
        let database = try AppDatabase.inMemory()
        try await TestData.saveServer(in: database, id: "s1") // cached lyrics belong to a server
        let client = try SubsonicClient(
            server: ServerAddress(TestData.address),
            auth: SubsonicAuth(username: "alice", credential: .plaintext(password: "pw")),
            transport: StubTransport(bodies: bodies)
        )
        let service = LyricsService(
            client: client, store: LyricsStore(database: database), serverID: "s1",
            supportsSongLyrics: openSubsonic, now: { Date(timeIntervalSince1970: 0) }
        )
        return (service, database)
    }

    @Test
    func `prefers synced lyrics by song id`() async throws {
        let (service, _) = try await service(["getLyricsBySongId": Self.synced])
        let lyrics = try await service.lyrics(for: TestData.song("1"))
        #expect(lyrics == .synced([.init(start: 0, text: "One"), .init(start: 2, text: "Two")]))
    }

    @Test
    func `falls back to the classic lookup by artist and title`() async throws {
        let (service, _) = try await service(["getLyrics": Self.plain], openSubsonic: false)
        let lyrics = try await service.lyrics(for: TestData.song("1"))
        #expect(lyrics == .plain("Plain\nwords"))
    }

    @Test
    func `nothing found is none`() async throws {
        let empty = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1","lyrics":{}}}"#.utf8)
        let (service, _) = try await service(["getLyrics": empty], openSubsonic: false)
        #expect(try await service.lyrics(for: TestData.song("1")) == .none)
    }

    @Test
    func `answers from the cache once fetched`() async throws {
        let (service, database) = try await service(["getLyricsBySongId": Self.synced])
        _ = try await service.lyrics(for: TestData.song("1"))

        let offline = try LyricsService(
            client: SubsonicClient(
                server: ServerAddress(TestData.address),
                auth: SubsonicAuth(username: "alice", credential: .plaintext(password: "pw")),
                transport: StubTransport(bodies: [:])
            ),
            store: LyricsStore(database: database), serverID: "s1", supportsSongLyrics: true, now: { .now }
        )
        #expect(try await offline.lyrics(for: TestData.song("1")) != .none)
    }

    @Test
    func `the current synced line is the last one started`() {
        let lines: [LyricsContent.Line] = [
            .init(start: 0, text: "a"),
            .init(start: 2, text: "b"),
            .init(start: 5, text: "c"),
        ]
        #expect(LyricsContent.currentLineIndex(in: lines, at: 0) == 0)
        #expect(LyricsContent.currentLineIndex(in: lines, at: 4.9) == 1)
        #expect(LyricsContent.currentLineIndex(in: lines, at: 100) == 2)
        #expect(LyricsContent.currentLineIndex(in: [.init(start: 1, text: "a")], at: 0) == nil)
    }

    @Test
    func `a failed lookup is reported and not cached as "no lyrics"`() async throws {
        let (service, database) = try await service([:]) // every request fails
        let untitled = Song(id: "9")

        await #expect(throws: SubsonicError.transport(.cannotConnectToHost)) {
            try await service.lyrics(for: untitled)
        }
        #expect(try await LyricsStore(database: database).lyrics(song: "9", server: "s1") == nil)
    }
}

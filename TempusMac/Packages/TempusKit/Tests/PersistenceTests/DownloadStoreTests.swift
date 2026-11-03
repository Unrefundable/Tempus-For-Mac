import Foundation
@testable import Persistence
import SubsonicAPI
import Testing

@Suite("Downloads and kept-synced playlists")
struct DownloadStoreTests {
    func database() async throws -> AppDatabase {
        let database = try AppDatabase.inMemory()
        for id in ["s1", "s2"] {
            try await ServerStore(database: database).save(ServerProfile(
                id: id, name: id, username: "u", address: ServerAddress("https://\(id).example.com"),
                localAddress: nil, usesPlaintextPassword: false, createdAt: Date(timeIntervalSince1970: 0)
            ))
        }
        return database
    }

    @Test("Downloads are kept per server, newest first, and deleted")
    func downloads() async throws {
        let database = try await database()
        let store = DownloadStore(database: database)
        try await store.save(
            DownloadRecord(
                song: Song(id: "a", title: "A"),
                fileName: "a.mp3",
                size: 10,
                downloadedAt: Date(timeIntervalSince1970: 1)
            ),
            server: "s1"
        )
        try await store.save(
            DownloadRecord(
                song: Song(id: "b", title: "B"), fileName: "b.flac", size: 20, playlistID: "p", playlistName: "Mix",
                downloadedAt: Date(timeIntervalSince1970: 2)
            ),
            server: "s1"
        )
        #expect(try await store.all(server: "s1").map(\.id) == ["b", "a"])
        #expect(try await store.all(server: "s2").isEmpty)
        #expect(try await store.record(songID: "b", server: "s1")?.playlistName == "Mix")

        try await store.delete(songIDs: ["b"], server: "s1")
        #expect(try await store.all(server: "s1").map(\.id) == ["a"])
        try await ServerStore(database: database).delete(id: "s1")
        #expect(try await store.all(server: "s1").isEmpty)
    }

    @Test("Kept-synced playlists are listed by name and removed")
    func syncedPlaylists() async throws {
        let store = try await SyncedPlaylistStore(database: database())
        try await store.add(SyncedPlaylist(id: "2", name: "Zeta"), server: "s1")
        try await store.add(SyncedPlaylist(id: "1", name: "Alpha"), server: "s1")
        #expect(try await store.all(server: "s1").map(\.id) == ["1", "2"])
        try await store.remove("1", server: "s1")
        #expect(try await store.all(server: "s1").map(\.name) == ["Zeta"])
    }
}

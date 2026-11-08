import Foundation
@testable import Persistence
import SubsonicAPI
import Testing

/// Review follow-ups: per-server data follows its server, and bad rows never break a load.
@Suite("Data lifecycle and robustness")
struct LifecycleTests {
    private func profile(
        _ id: String,
        username: String = "alice",
        address: String = "https://music.example.com",
        name: String = "Home"
    ) throws -> ServerProfile {
        try ServerProfile(
            id: id, name: name, username: username, address: ServerAddress(address),
            localAddress: nil, usesPlaintextPassword: false, createdAt: date(0)
        )
    }

    /// Fills every per-server table for `server`.
    private func fill(_ database: AppDatabase, server: String) async throws {
        try await QueueStore(database: database)
            .save(SavedQueue(songs: [song("q")], currentIndex: 0, positionMilliseconds: 1), server: server)
        try await HistoryStore(database: database).recordPlay(song("h"), server: server, at: date(1))
        try await PendingStarStore(database: database)
            .enqueue(PendingStar(target: .song("p"), isStarred: true, createdAt: date(1)), server: server)
        try await PinnedPlaylistStore(database: database).pin("pl", server: server)
        try await LyricsStore(database: database)
            .save(CachedLyrics(structured: [], plain: "x", updatedAt: date(1)), song: "s", server: server)
        try await ResponseCache(database: database).store(Data("r".utf8), key: "k", server: server, fetchedAt: date(1))
    }

    private func hasData(_ database: AppDatabase, server: String) async throws -> [Bool] {
        try await [
            QueueStore(database: database).load(server: server) != nil,
            !HistoryStore(database: database).recentlyPlayed(server: server, limit: 10).isEmpty,
            !PendingStarStore(database: database).pending(server: server).isEmpty,
            !PinnedPlaylistStore(database: database).pinned(server: server).isEmpty,
            LyricsStore(database: database).lyrics(song: "s", server: server) != nil,
            ResponseCache(database: database).entry(key: "k", server: server) != nil,
        ]
    }

    @Test("Deleting a server deletes all of its data and nobody else's")
    func deleteCascades() async throws {
        let database = try emptyDatabase()
        let servers = ServerStore(database: database)
        try await servers.save(profile("a"))
        try await servers.save(profile("b"))
        try await fill(database, server: "a")
        try await fill(database, server: "b")

        try await servers.delete(id: "a")

        #expect(try await hasData(database, server: "a") == Array(repeating: false, count: 6))
        #expect(try await hasData(database, server: "b") == Array(repeating: true, count: 6))
    }

    @Test("Changing the account or address clears the server's data", arguments: [
        ("bob", "https://music.example.com"),
        ("alice", "https://other.example.com"),
    ])
    func identityChangeClears(username: String, address: String) async throws {
        let database = try emptyDatabase()
        let servers = ServerStore(database: database)
        try await servers.save(profile("a"))
        try await fill(database, server: "a")

        try await servers.save(profile("a", username: username, address: address))

        #expect(try await hasData(database, server: "a") == Array(repeating: false, count: 6))
    }

    @Test("Renaming a server keeps its data")
    func renameKeeps() async throws {
        let database = try emptyDatabase()
        let servers = ServerStore(database: database)
        try await servers.save(profile("a"))
        try await fill(database, server: "a")

        try await servers.save(profile("a", name: "Renamed"))

        #expect(try await hasData(database, server: "a") == Array(repeating: true, count: 6))
    }

    @Test("Pinned playlists keep pin order; unpinning and pinning again moves one to the end")
    func pinOrder() async throws {
        let store = try PinnedPlaylistStore(database: seededDatabase())
        for id in ["p1", "p2", "p3"] {
            try await store.pin(id, server: "s")
        }
        try await store.unpin("p1", server: "s")
        try await store.pin("p1", server: "s")

        #expect(try await store.pinned(server: "s") == ["p2", "p3", "p1"])
    }

    @Test("A corrupt queue entry is skipped and an out-of-range current track is dropped")
    func corruptQueue() async throws {
        let database = try seededDatabase()
        let store = QueueStore(database: database)
        try await store.save(
            SavedQueue(songs: [song("a"), song("b")], currentIndex: 1, positionMilliseconds: 5),
            server: "s"
        )
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE queue SET song = 'not json' WHERE position = 0")
        }

        let queue = try #require(try await store.load(server: "s"))

        #expect(queue.songs.map(\.id) == ["b"])
        #expect(queue.currentIndex == nil)
        #expect(queue.positionMilliseconds == nil)
    }

    @Test("A server row with an unusable address is skipped, not fatal")
    func corruptServerRow() async throws {
        let database = try seededDatabase(servers: ["good"])
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE server SET address = 'not a url' WHERE id = 'good'")
            try db.execute(
                sql: """
                INSERT INTO server (id, name, username, address, uses_plaintext_password, created_at)
                VALUES ('fine', 'Fine', 'bob', 'https://fine.example.com', 0, ?)
                """,
                arguments: [date(5)]
            )
        }

        #expect(try await ServerStore(database: database).all().map(\.id) == ["fine"])
    }

    @Test("Unreadable cached lyrics are a cache miss")
    func corruptLyrics() async throws {
        let database = try seededDatabase()
        let store = LyricsStore(database: database)
        try await store.save(CachedLyrics(structured: [], plain: nil, updatedAt: date(1)), song: "x", server: "s")
        try await database.writer.write { try $0.execute(sql: "UPDATE lyrics_cache SET structured = '{'") }

        #expect(try await store.lyrics(song: "x", server: "s") == nil)
    }

    @Test("Pending stars of an unknown kind are skipped")
    func unknownStarKind() async throws {
        let database = try seededDatabase()
        try await database.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO pending_star (server_id, kind, target_id, is_starred, created_at)
                VALUES ('s', 'podcast', 'x', 1, ?)
                """,
                arguments: [date(1)]
            )
        }

        #expect(try await PendingStarStore(database: database).pending(server: "s").isEmpty)
    }

    @Test("Equal timestamps sort the same way every time")
    func tiesAreDeterministic() async throws {
        let database = try seededDatabase()
        let searches = RecentSearchStore(database: database)
        let history = HistoryStore(database: database)
        for query in ["b", "a", "c"] {
            try await searches.record(query, at: date(1))
        }
        for id in ["y", "x", "z"] {
            try await history.recordPlay(song(id), server: "s", at: date(1))
        }

        #expect(try await searches.recent() == ["a", "b", "c"])
        #expect(try await history.recentlyPlayed(server: "s", limit: 10).map(\.id) == ["x", "y", "z"])
    }

    @Test("Most played excludes plays at the end of the period; non-positive limits return nothing")
    func historyBounds() async throws {
        let store = try HistoryStore(database: seededDatabase())
        try await store.recordPlay(song("in"), server: "s", at: date(10))
        try await store.recordPlay(song("edge"), server: "s", at: date(100))

        #expect(try await store.mostPlayed(server: "s", from: date(0), to: date(100), limit: 5).map(\.id) == ["in"])
        #expect(try await store.recentlyPlayed(server: "s", limit: 0).isEmpty)
        #expect(try await store.mostPlayed(server: "s", from: date(0), to: date(200), limit: -1).isEmpty)
    }

    @Test("Old history can be pruned")
    func historyPrune() async throws {
        let store = try HistoryStore(database: seededDatabase())
        try await store.recordPlay(song("old"), server: "s", at: date(1))
        try await store.recordPlay(song("new"), server: "s", at: date(100))

        try await store.prune(olderThan: date(50))

        #expect(try await store.recentlyPlayed(server: "s", limit: 10).map(\.id) == ["new"])
    }

    @Test("A database file keeps its data across opens")
    func onDisk() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tempus-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "nested/Tempus.sqlite")

        try await ServerStore(database: AppDatabase.open(at: file)).save(profile("a"))
        let reopened = try AppDatabase.open(at: file)

        #expect(try await ServerStore(database: reopened).all().map(\.id) == ["a"])
        #expect(try reopened.appliedMigrations() == ["v1", "v2", "v3", "v4"])
    }
}

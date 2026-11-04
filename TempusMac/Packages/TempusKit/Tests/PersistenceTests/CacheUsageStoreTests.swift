import Foundation
@testable import Persistence
import SubsonicAPI
import Testing

@Suite("Measuring and clearing the cached library and lyrics")
struct CacheUsageStoreTests {
    @Test("Cached responses count their bodies' bytes across every server")
    func responseCacheBytes() async throws {
        // Arrange
        let cache = try ResponseCache(database: seededDatabase())
        try await cache.store(Data(count: 1000), key: "a", server: "s", fetchedAt: date(1))
        try await cache.store(Data(count: 500), key: "b", server: "other", fetchedAt: date(1))

        // Act
        let bytes = try await cache.totalBytes()

        // Assert
        #expect(bytes == 1500)
    }

    @Test("An empty response cache uses no bytes")
    func emptyResponseCache() async throws {
        let cache = try ResponseCache(database: seededDatabase())

        #expect(try await cache.totalBytes() == 0)
    }

    @Test("Clearing the response cache removes every server's entries")
    func clearResponseCache() async throws {
        // Arrange
        let cache = try ResponseCache(database: seededDatabase())
        try await cache.store(Data("v".utf8), key: "a", server: "s", fetchedAt: date(1))
        try await cache.store(Data("v".utf8), key: "b", server: "other", fetchedAt: date(1))

        // Act
        try await cache.clearAll()

        // Assert
        #expect(try await cache.entry(key: "a", server: "s") == nil)
        #expect(try await cache.entry(key: "b", server: "other") == nil)
        #expect(try await cache.totalBytes() == 0)
    }

    @Test("Cached lyrics count the bytes of their text, not its characters")
    func lyricsBytes() async throws {
        // Arrange
        let store = try LyricsStore(database: seededDatabase())
        // "é" is two bytes in UTF-8; the structured lyrics are stored as "[]" (two bytes).
        try await store.save(CachedLyrics(structured: [], plain: "café", updatedAt: date(1)), song: "1", server: "s")
        try await store.save(CachedLyrics(structured: [], plain: nil, updatedAt: date(1)), song: "2", server: "other")

        // Act
        let bytes = try await store.totalBytes()

        // Assert
        #expect(bytes == 2 + 5 + 2)
    }

    @Test("Clearing lyrics removes every server's lyrics")
    func clearLyrics() async throws {
        // Arrange
        let store = try LyricsStore(database: seededDatabase())
        try await store.save(CachedLyrics(structured: [], plain: "La", updatedAt: date(1)), song: "1", server: "s")
        try await store.save(CachedLyrics(structured: [], plain: "La", updatedAt: date(1)), song: "1", server: "other")

        // Act
        try await store.clearAll()

        // Assert
        #expect(try await store.lyrics(song: "1", server: "s") == nil)
        #expect(try await store.lyrics(song: "1", server: "other") == nil)
        #expect(try await store.totalBytes() == 0)
    }

    @Test("Compacting a database file on disk gives cleared space back, log included")
    func compactShrinksFile() async throws {
        // Arrange
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "CompactTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Tempus.sqlite")
        let database = try AppDatabase.open(at: file)
        try await database.writer.write { db in
            try db.execute(sql: """
            INSERT INTO server (id, name, username, address, uses_plaintext_password, created_at)
            VALUES ('s', 's', 'alice', 'https://music.example.com', 0, ?)
            """, arguments: [date(0)])
        }
        let cache = ResponseCache(database: database)
        for index in 0 ..< 30 {
            try await cache.store(Data(count: 100_000), key: "k\(index)", server: "s", fetchedAt: date(1))
        }
        try await cache.store(Data("kept".utf8), key: "kept", server: "s", fetchedAt: date(1))
        try await cache.clearAll()
        try await cache.store(Data("kept".utf8), key: "kept", server: "s", fetchedAt: date(1))
        let before = try Self.onDiskBytes(of: file)

        // Act
        try await database.compact()

        // Assert
        let after = try Self.onDiskBytes(of: file)
        #expect(before - after > 2_000_000)
        #expect(try await cache.entry(key: "kept", server: "s")?.data == Data("kept".utf8))
    }

    /// The database file and its write-ahead log.
    private static func onDiskBytes(of file: URL) throws -> Int {
        let files = FileManager.default
        return try [file.path, file.path + "-wal"].reduce(0) { total, path in
            guard files.fileExists(atPath: path) else { return total }
            return try total + (files.attributesOfItem(atPath: path)[.size] as? Int ?? 0)
        }
    }

    @Test("Compacting the database keeps what is left")
    func compact() async throws {
        // Arrange
        let database = try seededDatabase()
        let cache = ResponseCache(database: database)
        try await cache.store(Data("kept".utf8), key: "a", server: "s", fetchedAt: date(1))

        // Act
        try await database.compact()

        // Assert
        #expect(try await cache.entry(key: "a", server: "s")?.data == Data("kept".utf8))
    }
}

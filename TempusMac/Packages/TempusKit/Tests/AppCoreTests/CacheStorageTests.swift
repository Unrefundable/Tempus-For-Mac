@testable import AppCore
import Foundation
import Persistence
import Testing

@MainActor
struct CacheStorageTests {
    /// A disk artwork cache in its own folder, removed when the test ends.
    final class TemporaryArtwork {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CacheStorageTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        lazy var caches = ArtworkCaches.onDisk(at: directory)

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func filledStorage(
        artwork: TemporaryArtwork
    ) async throws -> (CacheStorage, AppDatabase) {
        let database = try AppDatabase.inMemory()
        let server = try await TestData.saveServer(in: database)
        try await ResponseCache(database: database)
            .store(Data(count: 2000), key: "getAlbum?id=1", server: server.id, fetchedAt: Date())
        try await LyricsStore(database: database)
            .save(CachedLyrics(structured: [], plain: "La la", updatedAt: Date()), song: "1", server: server.id)
        let disk = try #require(artwork.caches.disk)
        disk.storeData(Data(count: 4096), for: "server-1/cover/300")
        return (CacheStorage(database: database, artworkCaches: artwork.caches), database)
    }

    @Test
    func `measures cover art, library data and lyrics separately`() async throws {
        // Arrange
        let artwork = TemporaryArtwork()
        let (storage, _) = try await Self.filledStorage(artwork: artwork)

        // Act
        let usage = try await storage.usage()

        // Assert
        #expect(usage.bytes(for: .artwork) >= 4096)
        #expect(usage.bytes(for: .library) == 2000)
        #expect(usage.bytes(for: .lyrics) == 2 + 5)
        #expect(usage.totalBytes == usage.bytes(for: .artwork) + 2000 + 7)
    }

    @Test
    func `clearing cover art leaves library data and lyrics`() async throws {
        // Arrange
        let artwork = TemporaryArtwork()
        let (storage, _) = try await Self.filledStorage(artwork: artwork)

        // Act
        try await storage.clear([.artwork])
        let usage = try await storage.usage()

        // Assert
        #expect(usage.bytes(for: .artwork) == 0)
        #expect(usage.bytes(for: .library) == 2000)
        #expect(usage.bytes(for: .lyrics) == 7)
    }

    @Test
    func `lyrics count the lyrics search index, and clearing lyrics empties it too`() async throws {
        // Arrange
        let artwork = TemporaryArtwork()
        let (storage, database) = try await Self.filledStorage(artwork: artwork)
        let index = LyricsIndexStore(database: database)
        try await index.save(
            [LyricsIndexEntry(song: TestData.song("1"), fingerprint: "f", lyrics: "La la", checkedAt: Date())],
            server: "server-1"
        )
        let before = try await storage.usage().bytes(for: .lyrics)

        // Act
        try await storage.clear([.lyrics])

        // Assert
        #expect(before > 7)
        #expect(try await storage.usage().bytes(for: .lyrics) == 0)
        #expect(try await index.indexedSongs(server: "server-1").isEmpty)
        #expect(try await storage.usage().bytes(for: .library) == 2000)
    }

    @Test
    func `clearing everything empties every cache`() async throws {
        // Arrange
        let artwork = TemporaryArtwork()
        let (storage, _) = try await Self.filledStorage(artwork: artwork)

        // Act
        try await storage.clear(Set(CacheCategory.allCases))
        let usage = try await storage.usage()

        // Assert
        #expect(usage.totalBytes == 0)
    }

    @Test
    func `clearing never touches the saved queue`() async throws {
        // Arrange
        let artwork = TemporaryArtwork()
        let (storage, database) = try await Self.filledStorage(artwork: artwork)
        let queue = QueueStore(database: database)
        let saved = SavedQueue(songs: [TestData.song("1")], currentIndex: 0, positionMilliseconds: 0)
        try await queue.save(saved, server: "server-1")

        // Act
        try await storage.clear(Set(CacheCategory.allCases))

        // Assert
        #expect(try await queue.load(server: "server-1")?.songs.map(\.id) == ["1"])
    }

    @Test
    func `an in-memory artwork cache measures as empty and clears without error`() async throws {
        // Arrange
        let storage = try CacheStorage(database: AppDatabase.inMemory(), artworkCaches: .inMemory)

        // Act
        try await storage.clear([.artwork])

        // Assert
        #expect(try await storage.usage().bytes(for: .artwork) == 0)
    }

    // MARK: The Settings pane's model

    @Test
    func `the viewer loads usage, then clears and measures again`() async throws {
        // Arrange
        let artwork = TemporaryArtwork()
        let (storage, _) = try await Self.filledStorage(artwork: artwork)
        let viewer = CacheViewer(storage: storage)

        // Act
        await viewer.refresh()
        let before = viewer.usage
        await viewer.clear([.library])

        // Assert
        #expect(before?.bytes(for: .library) == 2000)
        #expect(viewer.usage?.bytes(for: .library) == 0)
        #expect(viewer.usage?.bytes(for: .lyrics) == 7)
        #expect(viewer.clearing.isEmpty)
        #expect(viewer.errorMessage == nil)
    }
}

@testable import AppCore
import Foundation
import Persistence
import Testing

struct LaunchMaintenanceTests {
    @Test
    func `prunes cached responses past the offline window and history past a year`() async throws {
        // Arrange
        let database = try AppDatabase.inMemory()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let day: TimeInterval = 24 * 60 * 60
        let server = try await TestData.saveServer(in: database)
        let cache = ResponseCache(database: database)
        try await cache.store(Data("old".utf8), key: "old", server: server.id, fetchedAt: now - 31 * day)
        try await cache.store(Data("new".utf8), key: "new", server: server.id, fetchedAt: now - 29 * day)
        let history = HistoryStore(database: database)
        try await history.recordPlay(TestData.song("1"), server: server.id, at: now - 400 * day)
        try await history.recordPlay(TestData.song("2"), server: server.id, at: now - 300 * day)

        // Act
        await LaunchMaintenance(database: database, now: { now }).run()

        // Assert
        #expect(try await cache.entry(key: "old", server: server.id) == nil)
        #expect(try await cache.entry(key: "new", server: server.id) != nil)
        let recent = try await history.recentlyPlayed(server: server.id, limit: 10)
        #expect(recent.map(\.id) == ["2"])
    }
}

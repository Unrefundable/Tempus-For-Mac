import Foundation
@testable import Persistence
import SubsonicAPI
import Testing

@Suite("Servers and recent searches")
struct AccountStoreTests {
    @Test("The schema migrates on an empty database and again without effect")
    func migratesTwice() throws {
        let database = try emptyDatabase()

        try AppDatabase.migrator.migrate(database.writer)

        #expect(try database.appliedMigrations() == ["v1", "v2", "v3", "v4"])
    }

    @Test("Servers are saved, listed in creation order, updated and deleted")
    func servers() async throws {
        let store = try ServerStore(database: emptyDatabase())
        let home = try ServerProfile(
            id: "srv-1", name: "Home", username: "alice",
            address: ServerAddress("https://music.example.com"),
            localAddress: ServerAddress("http://192.168.1.5:4533"),
            usesPlaintextPassword: false, createdAt: date(0)
        )
        let work = try ServerProfile(
            id: "srv-2", name: "Work", username: "bob",
            address: ServerAddress("https://work.example.com"),
            localAddress: nil, usesPlaintextPassword: true, createdAt: date(10)
        )

        try await store.save(work)
        try await store.save(home)
        #expect(try await store.all() == [home, work])

        let renamed = ServerProfile(
            id: home.id, name: "Home NAS", username: home.username, address: home.address,
            localAddress: nil, usesPlaintextPassword: home.usesPlaintextPassword, createdAt: home.createdAt
        )
        try await store.save(renamed)
        #expect(try await store.server(id: "srv-1") == renamed)

        try await store.delete(id: "srv-2")
        #expect(try await store.all() == [renamed])
    }

    @Test("Recent searches are newest first, de-duplicated and capped at 20")
    func recentSearches() async throws {
        let store = try RecentSearchStore(database: emptyDatabase())

        for index in 0 ..< 25 {
            try await store.record("query \(index)", at: date(TimeInterval(index)))
        }
        try await store.record("query 3", at: date(100))

        let recent = try await store.recent()
        #expect(recent.count == 20)
        #expect(recent.first == "query 3")
        #expect(recent.dropFirst().first == "query 24")
        #expect(!recent.contains("query 0"))

        try await store.remove("query 3")
        #expect(try await store.recent().first == "query 24")
    }

    @Test("Blank searches are not recorded")
    func blankSearch() async throws {
        let store = try RecentSearchStore(database: emptyDatabase())

        try await store.record("   ", at: date(0))

        #expect(try await store.recent().isEmpty)
    }
}

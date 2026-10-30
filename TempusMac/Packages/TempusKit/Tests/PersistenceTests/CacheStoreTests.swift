import Foundation
@testable import Persistence
import SubsonicAPI
import Testing

@Suite("Lyrics cache, local radio and response cache")
struct CacheStoreTests {
    @Test("Lyrics are cached per server and song, synced or plain")
    func lyrics() async throws {
        let store = try LyricsStore(database: seededDatabase())
        let synced = try JSONDecoder().decode(
            [StructuredLyrics].self,
            from: Data(#"[{"lang":"eng","synced":true,"line":[{"start":0,"value":"Hi"}]}]"#.utf8)
        )

        try await store.save(CachedLyrics(structured: synced, plain: nil, updatedAt: date(1)), song: "s1", server: "s")
        try await store.save(CachedLyrics(structured: [], plain: "La la", updatedAt: date(2)), song: "s2", server: "s")

        #expect(try await store.lyrics(song: "s1", server: "s")?.structured == synced)
        #expect(try await store.lyrics(song: "s2", server: "s")?.plain == "La la")
        #expect(try await store.lyrics(song: "s1", server: "other") == nil)
    }

    @Test("Local radio stations are added, edited, listed by name and deleted")
    func localRadio() async throws {
        let store = try LocalRadioStore(database: seededDatabase())
        let jazz = try LocalRadioStation(
            id: "r1", name: "Jazz FM",
            streamURL: #require(URL(string: "https://stream.example.com/jazz.mp3")),
            homePageURL: nil, coverArtURL: nil
        )
        let ambient = try LocalRadioStation(
            id: "r2", name: "Ambient",
            streamURL: #require(URL(string: "https://stream.example.com/ambient.aac")),
            homePageURL: URL(string: "https://ambient.example.com"), coverArtURL: nil
        )

        try await store.save(jazz)
        try await store.save(ambient)
        #expect(try await store.all().map(\.name) == ["Ambient", "Jazz FM"])

        let renamed = LocalRadioStation(
            id: "r1", name: "Jazz 24", streamURL: jazz.streamURL, homePageURL: nil, coverArtURL: nil
        )
        try await store.save(renamed)
        try await store.delete(id: "r2")
        #expect(try await store.all() == [renamed])
    }

    @Test("Cached responses are stored per server and key, and replaced on refresh")
    func responseCache() async throws {
        let cache = try ResponseCache(database: seededDatabase())

        try await cache.store(Data("v1".utf8), key: "getAlbum?id=1", server: "s", fetchedAt: date(1))
        try await cache.store(Data("v2".utf8), key: "getAlbum?id=1", server: "s", fetchedAt: date(2))

        let entry = try #require(try await cache.entry(key: "getAlbum?id=1", server: "s"))
        #expect(entry.data == Data("v2".utf8))
        #expect(entry.fetchedAt == date(2))
        #expect(try await cache.entry(key: "getAlbum?id=1", server: "other") == nil)
    }

    @Test("Pruning removes entries older than the cutoff; clearing removes a server's entries")
    func responseCachePruning() async throws {
        let cache = try ResponseCache(database: seededDatabase())
        try await cache.store(Data("old".utf8), key: "a", server: "s", fetchedAt: date(1))
        try await cache.store(Data("new".utf8), key: "b", server: "s", fetchedAt: date(100))
        try await cache.store(Data("x".utf8), key: "c", server: "other", fetchedAt: date(100))

        try await cache.prune(olderThan: date(50))
        #expect(try await cache.entry(key: "a", server: "s") == nil)
        #expect(try await cache.entry(key: "b", server: "s") != nil)

        try await cache.clear(server: "s")
        #expect(try await cache.entry(key: "b", server: "s") == nil)
        #expect(try await cache.entry(key: "c", server: "other") != nil)
    }
}

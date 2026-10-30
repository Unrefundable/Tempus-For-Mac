import Foundation
@testable import Persistence
import SubsonicAPI
import Testing

@Suite("Queue, history, pending stars and pinned playlists")
struct PlaybackStoreTests {
    @Test("A saved queue comes back in order with its current track and position")
    func queueRoundTrip() async throws {
        let store = try QueueStore(database: seededDatabase())
        let songs = try ["a", "b", "c"].map { try song($0) }

        try await store.save(SavedQueue(songs: songs, currentIndex: 1, positionMilliseconds: 42000), server: "srv-1")

        let queue = try #require(try await store.load(server: "srv-1"))
        #expect(queue.songs.map(\.id) == ["a", "b", "c"])
        #expect(queue.currentIndex == 1)
        #expect(queue.positionMilliseconds == 42000)
        #expect(try await store.load(server: "srv-2") == nil)
    }

    @Test("Saving replaces the previous queue; progress updates move the current track")
    func queueReplaceAndProgress() async throws {
        let store = try QueueStore(database: seededDatabase())
        try await store.save(SavedQueue(songs: [song("old")], currentIndex: 0, positionMilliseconds: 0), server: "s")
        try await store.save(
            SavedQueue(songs: [song("x"), song("y")], currentIndex: 0, positionMilliseconds: 0),
            server: "s"
        )

        try await store.updateProgress(currentIndex: 1, positionMilliseconds: 9000, server: "s")

        let queue = try #require(try await store.load(server: "s"))
        #expect(queue.songs.map(\.id) == ["x", "y"])
        #expect(queue.currentIndex == 1)
        #expect(queue.positionMilliseconds == 9000)
    }

    @Test("Duplicate songs in a queue are kept")
    func queueDuplicates() async throws {
        let store = try QueueStore(database: seededDatabase())

        try await store.save(
            SavedQueue(songs: [song("a"), song("a")], currentIndex: nil, positionMilliseconds: nil),
            server: "s"
        )

        #expect(try await store.load(server: "s")?.songs.map(\.id) == ["a", "a"])
    }

    @Test("Recently played lists each song once, latest play first")
    func recentlyPlayed() async throws {
        let store = try HistoryStore(database: seededDatabase())
        try await store.recordPlay(song("a"), server: "s", at: date(1))
        try await store.recordPlay(song("b"), server: "s", at: date(2))
        try await store.recordPlay(song("a"), server: "s", at: date(3))
        try await store.recordPlay(song("z"), server: "other", at: date(4))

        #expect(try await store.recentlyPlayed(server: "s", limit: 10).map(\.id) == ["a", "b"])
    }

    @Test("Most played counts plays within the period, most first")
    func mostPlayed() async throws {
        let store = try HistoryStore(database: seededDatabase())
        for (id, time) in [("a", 10.0), ("b", 11), ("b", 12), ("c", 13), ("c", 14), ("c", 15), ("c", 500)] {
            try await store.recordPlay(song(id), server: "s", at: date(time))
        }

        let top = try await store.mostPlayed(server: "s", from: date(0), to: date(100), limit: 20)

        #expect(top.map(\.id) == ["c", "b", "a"])
    }

    @Test("Pending stars queue up per server and are removed once synced")
    func pendingStars() async throws {
        let store = try PendingStarStore(database: seededDatabase())
        try await store.enqueue(PendingStar(target: .song("s1"), isStarred: true, createdAt: date(1)), server: "s")
        try await store.enqueue(PendingStar(target: .album("al1"), isStarred: false, createdAt: date(2)), server: "s")
        try await store.enqueue(PendingStar(target: .artist("ar1"), isStarred: true, createdAt: date(3)), server: "x")

        let pending = try await store.pending(server: "s")
        #expect(pending.map(\.change.target) == [.song("s1"), .album("al1")])
        #expect(pending.map(\.change.isStarred) == [true, false])

        try await store.remove(ids: [pending[0].id])
        #expect(try await store.pending(server: "s").map(\.change.target) == [.album("al1")])
    }

    @Test("Pinned playlists are per server and pinning twice is harmless")
    func pinnedPlaylists() async throws {
        let store = try PinnedPlaylistStore(database: seededDatabase())

        try await store.pin("p1", server: "s")
        try await store.pin("p1", server: "s")
        try await store.pin("p2", server: "s")
        try await store.pin("p9", server: "other")
        try await store.unpin("p2", server: "s")

        #expect(try await store.pinned(server: "s") == ["p1"])
        #expect(try await store.isPinned("p1", server: "s"))
        #expect(try await !store.isPinned("p1", server: "other"))
    }
}

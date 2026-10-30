import Foundation
@testable import Library
import Persistence
import SubsonicAPI
import Synchronization
import Testing

/// Answers with a body, or fails as if offline, and counts requests.
private final class StubServer: HTTPTransport {
    private let state: Mutex<(body: String?, requests: Int)>

    init(body: String?) {
        state = Mutex((body, 0))
    }

    var requests: Int {
        state.withLock { $0.requests }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let body = state.withLock { state -> String? in
            state.requests += 1
            return state.body
        }
        guard let body, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else { throw URLError(.notConnectedToInternet) }
        return (Data(body.utf8), response)
    }
}

private func albumsBody(_ ids: [String]) -> String {
    let albums = ids.map { #"{"id":"\#($0)"}"# }.joined(separator: ",")
    return #"{"subsonic-response":{"status":"ok","version":"1.16.1","albumList2":{"album":[\#(albums)]}}}"#
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)

@Suite("Cached library: show what we have, then refresh")
struct CachedLibraryTests {
    let cache: ResponseCache
    let request = SubsonicRequest<[Album]>.albumList(.newest)

    init() async throws {
        let database = try AppDatabase.inMemory()
        try await ServerStore(database: database).save(ServerProfile(
            id: "srv-1", name: "Home", username: "a", address: ServerAddress("https://music.example.com"),
            localAddress: nil, usesPlaintextPassword: false, createdAt: now
        ))
        cache = ResponseCache(database: database)
    }

    private func library(_ server: StubServer, maximumCachedBodySize: Int = 1 << 20) throws -> CachedLibrary {
        try CachedLibrary(
            client: SubsonicClient(
                server: ServerAddress("https://music.example.com"),
                auth: SubsonicAuth(username: "a", credential: .token(token: "t", salt: "s")),
                transport: server
            ),
            cache: cache,
            serverID: "srv-1",
            maximumCachedBodySize: maximumCachedBodySize,
            now: { now }
        )
    }

    @Test("A cache entry dated in the future (clock changed) is not shown")
    func futureEntryIgnored() async throws {
        try await cache.store(
            Data(albumsBody(["future"]).utf8),
            key: request.cacheKey,
            server: "srv-1",
            fetchedAt: now + 3600
        )

        #expect(try await collect(library(StubServer(body: albumsBody(["new"])))).snapshots == [["new"]])
    }

    @Test("Responses larger than the cap are returned but not cached")
    func oversizedNotCached() async throws {
        let albums = try await library(StubServer(body: albumsBody(["big"])), maximumCachedBodySize: 10)
            .refresh(request)

        #expect(albums.map(\.id) == ["big"])
        #expect(try await cache.entry(key: request.cacheKey, server: "srv-1") == nil)
    }

    @Test("Stopping after the first snapshot ends the stream cleanly")
    func earlyExit() async throws {
        try await cache.store(
            Data(albumsBody(["old"]).utf8),
            key: request.cacheKey,
            server: "srv-1",
            fetchedAt: now - 60
        )
        var seen: [[String]] = []

        for try await snapshot in try library(StubServer(body: albumsBody(["new"]))).snapshots(request) {
            seen.append(snapshot.value.map(\.id))
            break
        }

        #expect(seen == [["old"]])
    }

    /// What a screen would see: each snapshot's album ids and where it came from, then any error.
    private struct Collected {
        var snapshots: [[String]] = []
        var sources: [String] = []
        var error: (any Error)?
    }

    private func collect(_ library: CachedLibrary) async -> Collected {
        var collected = Collected()
        do {
            for try await snapshot in library.snapshots(request) {
                collected.snapshots.append(snapshot.value.map(\.id))
                collected.sources.append(snapshot.source == .server ? "server" : "cache")
            }
        } catch {
            collected.error = error
        }
        return collected
    }

    @Test("With nothing cached, the server's answer arrives alone and is cached")
    func firstLoad() async throws {
        let result = try await collect(library(StubServer(body: albumsBody(["a", "b"]))))

        #expect(result.snapshots == [["a", "b"]])
        #expect(result.sources == ["server"])
        #expect(try await cache.entry(key: request.cacheKey, server: "srv-1")?.fetchedAt == now)
    }

    @Test("A cached answer is shown first, then the fresh one")
    func cachedThenFresh() async throws {
        try await cache.store(
            Data(albumsBody(["old"]).utf8),
            key: request.cacheKey,
            server: "srv-1",
            fetchedAt: now - 60
        )

        let result = try await collect(library(StubServer(body: albumsBody(["new"]))))

        #expect(result.snapshots == [["old"], ["new"]])
        #expect(result.sources == ["cache", "server"])
        #expect(result.error == nil)
    }

    @Test("Offline with a cached answer: it is shown, then the network error is reported")
    func offlineWithCache() async throws {
        try await cache.store(
            Data(albumsBody(["old"]).utf8),
            key: request.cacheKey,
            server: "srv-1",
            fetchedAt: now - 60
        )

        let result = try await collect(library(StubServer(body: nil)))

        #expect(result.snapshots == [["old"]])
        #expect((result.error as? SubsonicError) == .transport(.notConnectedToInternet))
    }

    @Test("Offline with nothing cached: just the error")
    func offlineWithoutCache() async throws {
        let result = try await collect(library(StubServer(body: nil)))

        #expect(result.snapshots.isEmpty)
        #expect(result.error != nil)
    }

    @Test("Answers older than 30 days, or that no longer decode, are not shown")
    func staleOrCorruptCacheIgnored() async throws {
        let tooOld = now - CachedLibrary.maximumCacheAge - 1
        try await cache.store(
            Data(albumsBody(["stale"]).utf8),
            key: request.cacheKey,
            server: "srv-1",
            fetchedAt: tooOld
        )
        #expect(try await collect(library(StubServer(body: albumsBody(["new"])))).snapshots == [["new"]])

        try await cache.store(Data("garbage".utf8), key: request.cacheKey, server: "srv-1", fetchedAt: now)
        #expect(try await collect(library(StubServer(body: albumsBody(["new"])))).snapshots == [["new"]])
    }

    @Test("Refresh always asks the server and updates the cache")
    func refresh() async throws {
        let server = StubServer(body: albumsBody(["x"]))
        let library = try library(server)

        let albums = try await library.refresh(request)

        #expect(albums.map(\.id) == ["x"])
        #expect(server.requests == 1)
        #expect(try await cache.entry(key: request.cacheKey, server: "srv-1")?.data == Data(albumsBody(["x"]).utf8))
    }
}

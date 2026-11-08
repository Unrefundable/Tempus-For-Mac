@testable import AppCore
import Foundation
import Persistence
import SubsonicAPI
import Synchronization
import Testing

struct LyricsIndexerTests {
    let server: FakeLyricsServer
    let clock = TestClock()
    let index: LyricsIndexStore
    let indexer: LyricsIndexer

    init() async throws {
        server = FakeLyricsServer([
            .init(id: "1", lyrics: "Is this the real life\nIs this just fantasy"),
            .init(id: "2", lyrics: "Hello darkness my old friend"),
            .init(id: "3", lyrics: nil),
        ])
        let database = try AppDatabase.inMemory()
        try await TestData.saveServer(in: database, id: "s1")
        let client = try fakeLyricsClient(server)
        index = LyricsIndexStore(database: database)
        let lyrics = LyricsService(
            client: client, store: LyricsStore(database: database), serverID: "s1", supportsSongLyrics: true
        )
        indexer = LyricsIndexer(
            client: client, lyrics: lyrics, index: index, serverID: "s1",
            pageSize: 2, concurrentFetches: 2, now: { [clock] in clock.now }
        )
    }

    private func sync() async throws {
        try await indexer.syncIfNeeded { _ in }
    }

    private func found(_ query: String) async throws -> [String] {
        try await index.search(query, server: "s1").map(\.song.id)
    }

    @Test
    func `a first sync pages through every song and indexes its lyrics`() async throws {
        try await sync()

        // Two full pages, then an empty one that ends the listing.
        #expect(server.requests.filter { $0 == "search3" }.count == 3)
        #expect(try await found("real li") == ["1"])
        #expect(try await found("darkness") == ["2"])
        #expect(try await index.indexedSongs(server: "s1").count == 3)
    }

    @Test
    func `progress counts up to the songs fetched`() async throws {
        let reports = Mutex<[LyricsIndexProgress]>([])

        try await indexer.syncIfNeeded { progress in reports.withLock { $0.append(progress) } }

        let all = reports.withLock { $0 }
        #expect(all.first == LyricsIndexProgress(done: 0, total: 3))
        #expect(all.last == LyricsIndexProgress(done: 3, total: 3))
    }

    @Test
    func `nothing is listed or fetched again until the server scans`() async throws {
        try await sync()
        server.update { $0.requests = [] }

        try await sync()

        #expect(server.requests == ["getScanStatus"])
    }

    @Test
    func `after a scan only new and changed songs are fetched, and removed ones leave`() async throws {
        try await sync()
        server.update { state in
            state.tracks[0] = .init(id: "1", size: 200, lyrics: "Caught in a landslide")
            state.tracks.remove(at: 1)
            state.tracks.append(.init(id: "4", lyrics: "Sound of silence"))
            state.lastScan = "scan-2"
            state.requests = []
        }

        try await sync()

        #expect(server.requests.filter { $0 == "getLyricsBySongId" }.count == 2)
        #expect(try await found("landslide") == ["1"])
        #expect(try await found("real life").isEmpty)
        #expect(try await found("darkness").isEmpty)
        #expect(try await found("silence") == ["4"])
    }

    @Test
    func `songs without lyrics are asked about again after a week, not before`() async throws {
        try await sync()
        server.update { state in
            state.tracks[2].lyrics = "Added later"
            state.lastScan = "scan-2"
        }

        try await sync()
        #expect(try await found("added").isEmpty)

        clock.advance(days: 8)
        try await sync()
        #expect(try await found("added later") == ["3"])
    }

    @Test
    func `nothing is synced while the server is scanning`() async throws {
        server.update { $0.isScanning = true }

        try await sync()

        #expect(server.requests == ["getScanStatus"])
        #expect(try await index.indexedSongs(server: "s1").isEmpty)
    }

    @Test
    func `a song whose lyrics failed to load is tried again an hour later, not at every check`() async throws {
        server.update { $0.failing = ["2"] }
        try await sync()
        #expect(try await index.indexedSongs(server: "s1")["2"] == nil)
        server.update { state in
            state.failing = []
            state.requests = []
        }

        try await sync()
        #expect(server.requests == ["getScanStatus"])

        clock.advance(hours: 2)
        try await sync()
        #expect(server.requests.filter { $0 == "getLyricsBySongId" } == ["getLyricsBySongId"])
        #expect(try await found("darkness") == ["2"])
    }

    @Test
    func `songs the server refuses don't stop the others being indexed`() async throws {
        server.update { state in
            state.tracks = (1 ... 40).map { .init(id: "\($0)", lyrics: "words \($0)") }
            state.failing = Set((1 ... 30).map(String.init))
        }

        try await sync()

        #expect(server.requests.filter { $0 == "getLyricsBySongId" }.count == 40)
        #expect(try await index.indexedSongs(server: "s1").count == 10)
    }

    @Test
    func `the sync stops when the server can't be reached, keeping what arrived`() async throws {
        server.update { state in
            state.tracks = (1 ... 40).map { .init(id: "\($0)", lyrics: "words") }
            state.unreachable = Set((6 ... 40).map(String.init))
        }

        await #expect(throws: (any Error).self) { try await sync() }

        #expect(server.requests.filter { $0 == "getLyricsBySongId" }.count < 40)
        #expect(try await index.indexedSongs(server: "s1").keys.sorted() == ["1", "2", "3", "4", "5"])
    }

    @Test
    func `an empty listing never empties the index`() async throws {
        try await sync()
        server.update { state in
            state.listsNothing = true
            state.lastScan = "scan-2"
        }

        await #expect(throws: (any Error).self) { try await sync() }

        #expect(try await index.indexedSongs(server: "s1").count == 3)
        #expect(try await found("darkness") == ["2"])
    }

    @Test
    func `a server that sends shorter pages than asked is still listed in full`() async throws {
        server.update { $0.pageCap = 1 }

        try await sync()

        #expect(try await index.indexedSongs(server: "s1").count == 3)
    }

    @Test
    func `a scan starting while the library is listed leaves the index for the next check`() async throws {
        try await sync()
        server.update { state in
            state.tracks.remove(at: 1)
            state.lastScan = "scan-2"
            state.scansWhenListed = true
            state.requests = []
        }

        try await sync()

        #expect(!server.requests.contains("getLyricsBySongId"))
        #expect(try await found("darkness") == ["2"])
        #expect(try await index.state(server: "s1")?.lastScan == "scan-1")
    }
}

@MainActor
struct LyricsSearchTests {
    let server = FakeLyricsServer([.init(id: "1", lyrics: "Is this the real life")])
    let settings: AppSettings
    let index: LyricsIndexStore
    let indexer: LyricsIndexer

    init() async throws {
        let defaults = try #require(UserDefaults(suiteName: "LyricsSearchTests-\(UUID())"))
        settings = AppSettings(defaults: defaults)
        let database = try AppDatabase.inMemory()
        try await TestData.saveServer(in: database, id: "s1")
        let client = try fakeLyricsClient(server)
        index = LyricsIndexStore(database: database)
        let lyrics = LyricsService(
            client: client, store: LyricsStore(database: database), serverID: "s1", supportsSongLyrics: true
        )
        indexer = LyricsIndexer(client: client, lyrics: lyrics, index: index, serverID: "s1")
    }

    private func search(isOffline: Bool = false) -> LyricsSearch {
        LyricsSearch(indexer: indexer, index: index, serverID: "s1", settings: settings, isOffline: isOffline)
    }

    @Test
    func `lyrics search is off by default`() {
        #expect(!settings.searchesLyrics)
    }

    @Test
    func `while off, nothing is asked of the server and nothing is found`() async throws {
        let search = search()
        try await index.save(
            [LyricsIndexEntry(
                song: TestData.song("1"), fingerprint: "f", lyrics: "Is this the real life", checkedAt: .now
            )],
            server: "s1"
        )

        search.update()
        await search.stop()

        #expect(!search.isSyncing)
        #expect(server.requests.isEmpty)
        #expect(await search.search("real life").isEmpty)
    }

    @Test
    func `turning it on syncs, and turning it off keeps what was indexed`() async throws {
        let search = search()
        settings.searchesLyrics = true
        search.update()
        #expect(search.isSyncing)
        await search.stop()
        await search.syncNow()

        #expect(await search.search("real life").map(\.song.id) == ["1"])

        settings.searchesLyrics = false
        search.update()
        #expect(!search.isSyncing)
        #expect(try await index.indexedSongs(server: "s1").keys.sorted() == ["1"])
    }

    @Test
    func `turning it on while the index is being cleared waits until the clearing is done`() async {
        let search = search()
        settings.searchesLyrics = true

        await search.pausing {
            search.update()
            #expect(!search.isSyncing)
        }

        #expect(search.isSyncing)
        await search.stop()
    }

    @Test
    func `an offline session never syncs`() {
        settings.searchesLyrics = true
        let search = search(isOffline: true)

        search.update()

        #expect(!search.isSyncing)
    }
}

struct LyricsSearchMatchTests {
    @Test
    func `the line with the typed words is shown, with those words marked`() throws {
        let lyrics = "Is this the real life?\nIs this just fantasy?\nCaught in a landslide"

        let match = try #require(LyricsSearchMatch.bestLine(in: lyrics, for: "just fanta"))

        #expect(match.line == "Is this just fantasy?")
        #expect(match.highlights.map { String(match.line[$0]) } == ["just", "fantasy"])
    }

    @Test
    func `the line holding the words in order wins over one holding them apart`() throws {
        let lyrics = "Young we are not\nWe are young tonight"

        let match = try #require(LyricsSearchMatch.bestLine(in: lyrics, for: "we are young"))

        #expect(match.line == "We are young tonight")
    }

    @Test
    func `accents, case and apostrophes don't stop a word being marked`() throws {
        let match = try #require(LyricsSearchMatch.bestLine(in: "Don't wake Stjernestøv", for: "dont stjernestov"))

        #expect(match.highlights.map { String(match.line[$0]) } == ["Don't", "Stjernestøv"])
    }

    @Test
    func `words spread over several lines still show the first line with any of them`() throws {
        let match = try #require(LyricsSearchMatch.bestLine(in: "Hello\nmy old friend", for: "hello friend"))

        #expect(match.line == "Hello")
    }

    @Test
    func `empty lyrics or a query without words give no line`() {
        #expect(LyricsSearchMatch.bestLine(in: "", for: "hello") == nil)
        #expect(LyricsSearchMatch.bestLine(in: "Hello", for: " ?! ") == nil)
    }
}

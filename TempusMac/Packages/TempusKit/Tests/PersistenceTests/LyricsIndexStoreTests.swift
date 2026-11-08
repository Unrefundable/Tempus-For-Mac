import Foundation
import GRDB
@testable import Persistence
import SubsonicAPI
import Testing

@Suite("Lyrics search index")
struct LyricsIndexStoreTests {
    private func entry(
        _ id: String,
        _ lyrics: String,
        fingerprint: String = "f",
        checkedAt: Date = date(0)
    ) throws -> LyricsIndexEntry {
        try LyricsIndexEntry(song: song(id), fingerprint: fingerprint, lyrics: lyrics, checkedAt: checkedAt)
    }

    private func store(with entries: [LyricsIndexEntry], server: String = "s") async throws -> LyricsIndexStore {
        let store = try LyricsIndexStore(database: seededDatabase())
        try await store.save(entries, server: server)
        return store
    }

    @Test("A typed phrase finds the song it's sung in, the last word half typed")
    func phraseWithPartialLastWord() async throws {
        let store = try await store(with: [
            entry("1", "Is this the real life?\nIs this just fantasy?"),
            entry("2", "Real love is hard to find"),
        ])

        let matches = try await store.search("is this the real li", server: "s")

        #expect(matches.map(\.song.id) == ["1"])
    }

    /// The words far apart: in the first line, the middle and the last line, with filler between.
    private static let scattered = """
    Kiss the sky tonight
    la la la la la la la la la la
    you were never me before
    la la la la la la la la la la
    and then we go home
    """

    @Test("Songs with the exact phrase rank above songs with the words close together")
    func phraseRanksFirst() async throws {
        let store = try await store(with: [
            entry("close", "The night is young\nand we are running home"),
            entry("phrase", "We are young tonight"),
        ])

        let matches = try await store.search("we are young", server: "s")

        #expect(matches.map(\.song.id) == ["phrase", "close"])
    }

    @Test("A line typed with a word missing finds the song, and songs with the words scattered stay out")
    func missingWordBeatsScattered() async throws {
        let store = try await store(with: [
            entry("scattered", Self.scattered),
            entry("summertime", "Kiss me hard before you go\nSummertime sadness"),
        ])

        let matches = try await store.search("kiss me before you go", server: "s")

        #expect(matches.map(\.song.id) == ["summertime"])
    }

    @Test("An exact phrase isn't followed by songs that only have the words scattered")
    func phraseHidesScattered() async throws {
        let store = try await store(with: [
            entry("scattered", Self.scattered + "\nhard times"),
            entry("summertime", "Kiss me hard before you go"),
        ])

        let matches = try await store.search("kiss me hard before", server: "s")

        #expect(matches.map(\.song.id) == ["summertime"])
    }

    @Test("Words a couple apart rank above words a line apart")
    func closeRanksAboveNearby() async throws {
        let store = try await store(with: [
            entry("nearby", "Kiss the girl in the rain, said me"),
            entry("close", "Kiss her and me"),
        ])

        let matches = try await store.search("kiss me", server: "s")

        #expect(matches.map(\.song.id) == ["close", "nearby"])
    }

    @Test("Songs with the words scattered are shown when nothing closer matches")
    func scatteredAsLastResort() async throws {
        let store = try await store(with: [entry("scattered", Self.scattered)])

        let matches = try await store.search("kiss me before you go", server: "s")

        #expect(matches.map(\.song.id) == ["scattered"])
    }

    @Test("Accents and case don't matter")
    func foldsAccentsAndCase() async throws {
        let store = try await store(with: [entry("1", "Under Stjernestøv og månelys\nIn der Straße, Æon")])

        #expect(try await store.search("STJERNESTOV", server: "s").map(\.song.id) == ["1"])
        #expect(try await store.search("manelys", server: "s").map(\.song.id) == ["1"])
        #expect(try await store.search("strasse aeon", server: "s").map(\.song.id) == ["1"])
        #expect(try await store.search("straße", server: "s").map(\.song.id) == ["1"])
    }

    @Test("A finished last word, followed by a space, has to match whole")
    func trailingSpaceEndsThePrefix() async throws {
        let store = try await store(with: [entry("1", "Loving you"), entry("2", "Love me")])

        #expect(try await store.search("lov", server: "s").count == 2)
        #expect(try await store.search("love ", server: "s").map(\.song.id) == ["2"])
    }

    @Test("Apostrophes don't matter, typed or not")
    func apostrophes() async throws {
        let store = try await store(with: [entry("1", "Don't stop believin'"), entry("2", "We can’t stop")])

        #expect(try await store.search("dont stop", server: "s").map(\.song.id) == ["1"])
        #expect(try await store.search("don't stop", server: "s").map(\.song.id) == ["1"])
        #expect(try await store.search("cant", server: "s").map(\.song.id) == ["2"])
    }

    @Test("A single typed letter matches only that word, not every word it starts")
    func singleLetter() async throws {
        let store = try await store(with: [entry("1", "And so it goes"), entry("2", "A day in the life")])

        #expect(try await store.search("a", server: "s").map(\.song.id) == ["2"])
        #expect(try await store.search("an", server: "s").map(\.song.id) == ["1"])
    }

    @Test("Quotes and search operators in the query are taken as plain text")
    func operatorsAreLiteral() async throws {
        let store = try await store(with: [entry("1", "Rock and roll NEAR the sea")])

        #expect(try await store.search(#"rock" OR "x"#, server: "s").isEmpty)
        #expect(try await store.search("near the sea", server: "s").map(\.song.id) == ["1"])
        #expect(try await store.search(#""*(^"#, server: "s").isEmpty)
    }

    @Test("Each server only finds its own songs")
    func perServer() async throws {
        let store = try await store(with: [entry("1", "Hello darkness")])
        try await store.save([entry("2", "Hello darkness")], server: "other")

        #expect(try await store.search("hello darkness", server: "s").map(\.song.id) == ["1"])
        #expect(try await store.search("hello darkness", server: "other").map(\.song.id) == ["2"])
    }

    @Test("Saving a song again replaces its lyrics in the search")
    func replacesOnSave() async throws {
        let store = try await store(with: [entry("1", "Old words")])
        try await store.save([entry("1", "New words", fingerprint: "g")], server: "s")

        #expect(try await store.search("old", server: "s").isEmpty)
        #expect(try await store.search("new", server: "s").map(\.song.id) == ["1"])
        #expect(try await store.indexedSongs(server: "s")["1"]?.fingerprint == "g")
    }

    @Test("Removed songs leave the search")
    func removes() async throws {
        let store = try await store(with: [entry("1", "Goodbye"), entry("2", "Goodbye again")])

        try await store.remove(songs: ["1"], server: "s")

        #expect(try await store.search("goodbye", server: "s").map(\.song.id) == ["2"])
        #expect(try await store.indexedSongs(server: "s").keys.sorted() == ["2"])
    }

    @Test("Deleting a server deletes its index and search entries")
    func deletedWithServer() async throws {
        let database = try seededDatabase()
        let store = LyricsIndexStore(database: database)
        try await store.save([entry("1", "Hello")], server: "s")
        try await store.setState(LyricsIndexState(lastScan: "x", syncedAt: date(1)), server: "s")

        try await database.writer.write { try $0.execute(sql: "DELETE FROM server WHERE id = 's'") }

        #expect(try await store.indexedSongs(server: "s").isEmpty)
        #expect(try await store.state(server: "s") == nil)
        #expect(try await store.search("hello", server: "s").isEmpty)
        let ftsRows = try await database.writer.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM lyrics_index_fts WHERE lyrics_index_fts MATCH 'hello'")
        }
        #expect(ftsRows == 0)
    }

    @Test("A connection that knows nothing of lyrics search, such as an older Tempus, can still delete a server")
    func plainConnectionDeletes() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tempus-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Tempus.sqlite")
        let database = try AppDatabase.open(at: file)
        try await database.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO server (id, name, username, address, uses_plaintext_password, created_at)
                VALUES ('s', 's', 'alice', 'https://music.example.com', 0, ?)
                """,
                arguments: [date(0)]
            )
        }
        try await LyricsIndexStore(database: database).save([entry("1", "Stjernestøv")], server: "s")

        let plain = try DatabaseQueue(path: file.path)
        try await plain.write { try $0.execute(sql: "DELETE FROM server WHERE id = 's'") }

        let left = try await plain.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM lyrics_index") }
        #expect(left == 0)
    }

    @Test("An index built before v4 learns which songs have lyrics")
    func migratesHasLyrics() async throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v3")
        try await queue.write { db in
            try db.execute(sql: """
            INSERT INTO server (id, name, username, address, uses_plaintext_password, created_at)
            VALUES ('s', 's', 'alice', 'https://music.example.com', 0, 0);
            INSERT INTO lyrics_index (server_id, song_id, song, fingerprint, lyrics, search_text, checked_at)
            VALUES ('s', '1', '{"id":"1"}', 'f', 'Words', 'Words', 0), ('s', '2', '{"id":"2"}', 'f', '', '', 0);
            """)
        }

        try AppDatabase.migrator.migrate(queue)

        let flags = try await queue.read {
            try Row.fetchAll($0, sql: "SELECT song_id, has_lyrics FROM lyrics_index ORDER BY song_id")
                .map { [$0["song_id"] as String: $0["has_lyrics"] as Bool] }
        }
        #expect(flags == [["1": true], ["2": false]])
    }

    @Test("Songs without lyrics are remembered but never found")
    func emptyLyrics() async throws {
        let store = try await store(with: [entry("1", "", checkedAt: date(5))])

        let indexed = try #require(try await store.indexedSongs(server: "s")["1"])
        #expect(!indexed.hasLyrics)
        #expect(indexed.checkedAt == date(5))
        #expect(try await store.search("a", server: "s").isEmpty)
    }

    @Test("An empty or punctuation-only query finds nothing")
    func emptyQuery() async throws {
        let store = try await store(with: [entry("1", "Words")])

        #expect(try await store.search("", server: "s").isEmpty)
        #expect(try await store.search("  ?! ", server: "s").isEmpty)
    }

    @Test("Results stop at the limit")
    func limit() async throws {
        let store = try await store(with: (1 ... 5).map { try entry("\($0)", "la la la") })

        #expect(try await store.search("la", server: "s", limit: 3).count == 3)
    }

    @Test("Sync state is kept per server")
    func state() async throws {
        let store = try LyricsIndexStore(database: seededDatabase())
        let state = LyricsIndexState(lastScan: "2026-11-07T17:00:00Z", syncedAt: date(9))

        try await store.setState(state, server: "s")

        #expect(try await store.state(server: "s") == state)
        #expect(try await store.state(server: "other") == nil)
    }

    @Test("Size counts the index, and clearing empties it with the search entries")
    func sizeAndClear() async throws {
        let store = try await store(with: [entry("1", "Some words")])
        try await store.setState(LyricsIndexState(lastScan: nil, syncedAt: date(1)), server: "s")
        #expect(try await store.totalBytes() > 0)

        try await store.clearAll()

        #expect(try await store.totalBytes() == 0)
        #expect(try await store.search("words", server: "s").isEmpty)
        #expect(try await store.state(server: "s") == nil)
    }
}

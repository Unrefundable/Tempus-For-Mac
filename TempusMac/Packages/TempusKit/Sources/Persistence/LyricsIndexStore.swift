import Foundation
import GRDB
import SubsonicAPI

/// One song in the lyrics search index.
public struct LyricsIndexEntry: Sendable, Equatable {
    public let song: Song
    /// Changes when the song's file does, so its lyrics are fetched again.
    public let fingerprint: String
    /// The lyrics as plain lines, empty when the song has none.
    public let lyrics: String
    public let checkedAt: Date

    public init(song: Song, fingerprint: String, lyrics: String, checkedAt: Date) {
        self.song = song
        self.fingerprint = fingerprint
        self.lyrics = lyrics
        self.checkedAt = checkedAt
    }
}

/// What the index knows of a song, to tell whether it needs fetching again.
public struct IndexedSong: Sendable, Equatable {
    public let fingerprint: String
    public let hasLyrics: Bool
    public let checkedAt: Date

    public init(fingerprint: String, hasLyrics: Bool, checkedAt: Date) {
        self.fingerprint = fingerprint
        self.hasLyrics = hasLyrics
        self.checkedAt = checkedAt
    }
}

/// When a server's index was last brought up to date, and the server's last scan it saw then.
public struct LyricsIndexState: Sendable, Equatable {
    /// The server's own marker for its last library scan, compared only for a change.
    public let lastScan: String?
    public let syncedAt: Date

    public init(lastScan: String?, syncedAt: Date) {
        self.lastScan = lastScan
        self.syncedAt = syncedAt
    }
}

/// A song whose lyrics match a search, with all its lyrics so the matching line can be shown.
public struct LyricsIndexMatch: Sendable, Equatable {
    public let song: Song
    public let lyrics: String

    public init(song: Song, lyrics: String) {
        self.song = song
        self.lyrics = lyrics
    }
}

/// Each server's songs' lyrics, searchable as full text. Rows of songs without lyrics are kept
/// too, so they aren't fetched again on every sync.
public struct LyricsIndexStore: Sendable {
    /// How many songs a search returns unless asked otherwise.
    public static let defaultLimit = 25
    /// Rows deleted per statement, well under SQLite's bound-variable limit.
    private static let deleteBatchSize = 500

    private let writer: any DatabaseWriter

    public init(database: AppDatabase) {
        writer = database.writer
    }

    /// Adds `entries`, replacing the same songs' earlier entries, in one transaction.
    public func save(_ entries: [LyricsIndexEntry], server: String) async throws {
        guard !entries.isEmpty else { return }
        let rows = try entries.map { entry in
            try [
                server, entry.song.id, SongJSON.encode(entry.song), entry.fingerprint,
                entry.lyrics, LyricsFolding.fold(entry.lyrics), !entry.lyrics.isEmpty, entry.checkedAt,
            ] as StatementArguments
        }
        try await writer.write { db in
            // An upsert, not INSERT OR REPLACE: a REPLACE deletes without running the delete
            // trigger that keeps the full-text table in step.
            let statement = try db.makeStatement(sql: """
            INSERT INTO lyrics_index (
                server_id, song_id, song, fingerprint, lyrics, search_text, has_lyrics, checked_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (server_id, song_id) DO UPDATE SET
                song = excluded.song, fingerprint = excluded.fingerprint, lyrics = excluded.lyrics,
                search_text = excluded.search_text, has_lyrics = excluded.has_lyrics, checked_at = excluded.checked_at
            """)
            for row in rows {
                try statement.execute(arguments: row)
            }
        }
    }

    public func remove(songs: Set<String>, server: String) async throws {
        guard !songs.isEmpty else { return }
        let batches = Array(songs).chunked(into: Self.deleteBatchSize)
        try await writer.write { db in
            for batch in batches {
                try Table("lyrics_index")
                    .filter(Column("server_id") == server && batch.contains(Column("song_id")))
                    .deleteAll(db)
            }
        }
    }

    /// Every song in `server`'s index, by song ID.
    public func indexedSongs(server: String) async throws -> [String: IndexedSong] {
        try await writer.read { db in
            let rows = try Row.fetchCursor(
                db,
                sql: """
                SELECT song_id, fingerprint, has_lyrics, checked_at
                FROM lyrics_index WHERE server_id = ?
                """,
                arguments: [server]
            )
            var songs: [String: IndexedSong] = [:]
            while let row = try rows.next() {
                songs[row["song_id"]] = IndexedSong(
                    fingerprint: row["fingerprint"], hasLyrics: row["has_lyrics"], checkedAt: row["checked_at"]
                )
            }
            return songs
        }
    }

    /// Songs whose lyrics contain `query`'s words, best first: the words as a phrase, then the
    /// words anywhere. The last word matches as a prefix while it may still be being typed, that
    /// is unless the query ends in a space or punctuation, or it is a single letter, which would
    /// match nearly every song. Search syntax in `query` is taken as plain words.
    public func search(_ query: String, server: String, limit: Int = defaultLimit) async throws -> [LyricsIndexMatch] {
        try await writer.read { db in
            guard limit > 0, let patterns = try LyricsPatterns(query: query, db: db) else { return [] }
            var matches = try Self.matches(db, pattern: patterns.phrase, server: server, limit: limit)
            if matches.count < limit, let allWords = patterns.allWords {
                let found = Set(matches.map(\.song.id))
                let more = try Self.matches(db, pattern: allWords, server: server, limit: limit + found.count)
                matches += more.lazy.filter { !found.contains($0.song.id) }.prefix(limit - matches.count)
            }
            return matches
        }
    }

    public func state(server: String) async throws -> LyricsIndexState? {
        try await writer.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT last_scan, synced_at FROM lyrics_index_state WHERE server_id = ?",
                arguments: [server]
            ).map { LyricsIndexState(lastScan: $0["last_scan"], syncedAt: $0["synced_at"]) }
        }
    }

    public func setState(_ state: LyricsIndexState, server: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO lyrics_index_state (server_id, last_scan, synced_at) VALUES (?, ?, ?)
                ON CONFLICT (server_id) DO UPDATE SET last_scan = excluded.last_scan, synced_at = excluded.synced_at
                """,
                arguments: [server, state.lastScan, state.syncedAt]
            )
        }
    }

    /// The UTF-8 size of every server's index: the songs and lyrics kept, and the full-text
    /// index built from them.
    public func totalBytes() async throws -> Int64 {
        try await writer.read { db in
            let content = try Int64.fetchOne(db, sql: """
            SELECT COALESCE(SUM(
                LENGTH(CAST(song AS BLOB)) + LENGTH(CAST(lyrics AS BLOB)) + LENGTH(CAST(search_text AS BLOB))
            ), 0) FROM lyrics_index
            """) ?? 0
            // An empty full-text table still holds a few bytes of bookkeeping; that isn't lyrics.
            guard content > 0 else { return 0 }
            let index = try Int64.fetchOne(
                db, sql: "SELECT COALESCE(SUM(LENGTH(block)), 0) FROM lyrics_index_fts_data"
            ) ?? 0
            return content + index
        }
    }

    /// Empties every server's index; it is built again the next time lyrics search syncs.
    public func clearAll() async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM lyrics_index")
            try db.execute(sql: "DELETE FROM lyrics_index_state")
        }
    }

    private static func matches(
        _ db: Database,
        pattern: String,
        server: String,
        limit: Int
    ) throws -> [LyricsIndexMatch] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT lyrics_index.song, lyrics_index.lyrics
            FROM lyrics_index_fts
            JOIN lyrics_index ON lyrics_index.id = lyrics_index_fts.rowid
            WHERE lyrics_index_fts MATCH ? AND lyrics_index.server_id = ?
            ORDER BY lyrics_index_fts.rank
            LIMIT ?
            """,
            arguments: [pattern, server, limit]
        )
        return rows.compactMap { row in
            do {
                return try LyricsIndexMatch(song: SongJSON.decode(row["song"]), lyrics: row["lyrics"])
            } catch {
                persistenceLogger.error("Ignoring an unreadable song in the lyrics index: \(error)")
                return nil
            }
        }
    }
}

/// FTS5 queries built from what the user typed. Each word is quoted, so nothing typed is read as
/// search syntax.
struct LyricsPatterns: Equatable {
    /// The words in order.
    let phrase: String
    /// Every word, anywhere; nil for a single word, where it would equal `phrase`.
    let allWords: String?

    /// Nil when `query` has no words.
    init?(query: String, db: Database) throws {
        let tokens = try db.makeTokenizer(AppDatabase.lyricsTokenizer).tokenize(query: LyricsFolding.fold(query))
            .compactMap { $0.flags.contains(.colocated) ? nil : $0.token }
        guard let last = tokens.last else { return nil }
        let isLastWordFinished = query.last.map { $0.isWhitespace || $0.isPunctuation } ?? true
        let prefix = isLastWordFinished || last.count < Self.shortestPrefix ? "" : "*"
        phrase = Self.quoted(tokens.joined(separator: " ")) + prefix
        allWords = tokens.count > 1
            ? (tokens.dropLast().map(Self.quoted) + [Self.quoted(last) + prefix]).joined(separator: " ")
            : nil
    }

    /// Fewer letters than this are matched as a whole word.
    private static let shortestPrefix = 2

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
    }
}

/// Text as lyrics search compares it, before SQLite's tokenizer lowercases it and removes accents:
/// apostrophes dropped, so "dont" finds "don't" (the tokenizer would split it into "don" and "t"),
/// and Latin letters spelled in ASCII (ø → o, æ → ae, ß → ss, ł → l), which accent removal leaves
/// alone since they have no accent to remove. Other scripts pass through. Applied to lyrics as
/// they're indexed and to every search, so typing on any keyboard finds the lyric.
public enum LyricsFolding {
    private static let apostrophes: Set<Character> = ["'", "\u{2019}", "\u{02BC}"]

    public static func fold(_ text: String) -> String {
        let joined = text.filter { !apostrophes.contains($0) }
        // Most lyrics are ASCII already and skip the transform.
        guard !joined.utf8.allSatisfy({ $0 < 0x80 }) else { return joined }
        return joined.applyingTransform(StringTransform("Latin-ASCII"), reverse: false) ?? joined
    }
}

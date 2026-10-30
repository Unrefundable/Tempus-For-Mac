import Foundation
import GRDB
import SubsonicAPI

/// The play queue as it was when the app last saved it ("continue where you left off").
public struct SavedQueue: Sendable, Equatable {
    public let songs: [Song]
    public let currentIndex: Int?
    public let positionMilliseconds: Int64?

    public init(songs: [Song], currentIndex: Int?, positionMilliseconds: Int64?) {
        self.songs = songs
        self.currentIndex = currentIndex
        self.positionMilliseconds = positionMilliseconds
    }
}

/// The saved play queue per server, with the current track and position.
public struct QueueStore: Sendable {
    private let writer: any DatabaseWriter

    public init(database: AppDatabase) {
        writer = database.writer
    }

    /// Replaces the server's saved queue.
    public func save(_ queue: SavedQueue, server: String) async throws {
        let rows = try queue.songs.map(SongJSON.encode)
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM queue WHERE server_id = ?", arguments: [server])
            for (position, song) in rows.enumerated() {
                try db.execute(
                    sql: "INSERT INTO queue (server_id, position, song) VALUES (?, ?, ?)",
                    arguments: [server, position, song]
                )
            }
            try Self.writeState(db, server: server, index: queue.currentIndex, position: queue.positionMilliseconds)
        }
    }

    /// Records the current track and position, as upstream does on pause, skip and every few seconds.
    public func updateProgress(currentIndex: Int, positionMilliseconds: Int64, server: String) async throws {
        try await writer.write { db in
            try Self.writeState(db, server: server, index: currentIndex, position: positionMilliseconds)
        }
    }

    /// Nil when nothing has been saved for `server`. An entry that no longer decodes is logged and
    /// skipped; the current track and position are then dropped, since they may point elsewhere.
    public func load(server: String) async throws -> SavedQueue? {
        let (rows, state) = try await writer.read { db in
            let rows = try String.fetchAll(
                db, sql: "SELECT song FROM queue WHERE server_id = ? ORDER BY position", arguments: [server]
            )
            let state = try Row.fetchOne(
                db, sql: "SELECT current_index, position_ms FROM queue_state WHERE server_id = ?", arguments: [server]
            ).map { row -> (index: Int?, position: Int64?) in (row["current_index"], row["position_ms"]) }
            return (rows, state)
        }
        guard !rows.isEmpty || state != nil else { return nil }
        let songs = decodeSkippingBad(rows, what: "queue entry")
        let isIntact = songs.count == rows.count
        let index = state?.index.flatMap { songs.indices.contains($0) && isIntact ? $0 : nil }
        return SavedQueue(
            songs: songs,
            currentIndex: index,
            positionMilliseconds: index == nil ? nil : state?.position
        )
    }

    private static func writeState(_ db: Database, server: String, index: Int?, position: Int64?) throws {
        try db.execute(
            sql: """
            INSERT INTO queue_state (server_id, current_index, position_ms) VALUES (?, ?, ?)
            ON CONFLICT(server_id) DO UPDATE SET
            current_index = excluded.current_index, position_ms = excluded.position_ms
            """,
            arguments: [server, index, position]
        )
    }
}

/// Every play, for "Last played" and "Most played" (upstream's chronology table).
public struct HistoryStore: Sendable {
    private let writer: any DatabaseWriter

    public init(database: AppDatabase) {
        writer = database.writer
    }

    public func recordPlay(_ song: Song, server: String, at date: Date) async throws {
        let json = try SongJSON.encode(song)
        try await writer.write { db in
            try db.execute(
                sql: "INSERT INTO play_history (server_id, song_id, song, played_at) VALUES (?, ?, ?, ?)",
                arguments: [server, song.id, json, date]
            )
        }
    }

    /// Each song once, most recently played first. Ties are broken by song id.
    public func recentlyPlayed(server: String, limit: Int) async throws -> [Song] {
        guard limit > 0 else { return [] }
        // SQLite returns the bare `song` column from the row holding MAX(played_at).
        return try await songs(
            sql: """
            SELECT song, MAX(played_at) AS last_played FROM play_history WHERE server_id = ?
            GROUP BY song_id ORDER BY last_played DESC, song_id LIMIT ?
            """,
            arguments: [server, limit]
        )
    }

    /// Songs played most often in `from..<to`, as upstream's weekly/monthly/yearly sections.
    public func mostPlayed(server: String, from: Date, to: Date, limit: Int) async throws -> [Song] {
        guard limit > 0 else { return [] }
        return try await songs(
            sql: """
            SELECT song, COUNT(*) AS plays, MAX(played_at) AS last_played FROM play_history
            WHERE server_id = ? AND played_at >= ? AND played_at < ?
            GROUP BY song_id ORDER BY plays DESC, last_played DESC, song_id LIMIT ?
            """,
            arguments: [server, from, to, limit]
        )
    }

    /// Forgets plays before `cutoff`. The longest Home section looks back a year.
    public func prune(olderThan cutoff: Date) async throws {
        try await writer
            .write { try $0.execute(sql: "DELETE FROM play_history WHERE played_at < ?", arguments: [cutoff]) }
    }

    private func songs(sql: String, arguments: StatementArguments) async throws -> [Song] {
        let rows = try await writer.read { db in
            try Row.fetchAll(db, sql: sql, arguments: arguments).map { row -> String in row["song"] }
        }
        return decodeSkippingBad(rows, what: "history entry")
    }
}

/// Decodes stored songs, logging and skipping any that no longer decode.
private func decodeSkippingBad(_ rows: [String], what: String) -> [Song] {
    rows.compactMap { row in
        do {
            return try SongJSON.decode(row)
        } catch {
            persistenceLogger.error("Skipping an unreadable \(what, privacy: .public): \(error)")
            return nil
        }
    }
}

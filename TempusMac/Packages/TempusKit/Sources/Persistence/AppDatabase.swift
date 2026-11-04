import Foundation
import GRDB
import os

let persistenceLogger = Logger(subsystem: "io.github.unrefundable.TempusMac", category: "Persistence")

/// The app's SQLite database. Mirrors the parts of upstream's Room schema (v24) the Mac needs,
/// scoped per server, plus a response cache for library browsing.
public struct AppDatabase: Sendable {
    let writer: any DatabaseWriter

    /// Opens `writer` and brings its schema up to date.
    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// A private in-memory database, for tests and previews.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(configuration: configuration))
    }

    /// The database file at `url`, created if needed. Use a location inside the app's container
    /// (Application Support), which the sandbox keeps private to this app. A pool lets reads run
    /// while a write is in progress.
    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try AppDatabase(DatabasePool(path: url.path, configuration: configuration))
    }

    /// Foreign keys are on by default in GRDB. Deleted rows (listening history, cached responses)
    /// are overwritten on disk rather than left in free pages.
    private static var configuration: Configuration {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
        }
        return configuration
    }

    /// Free space below this isn't worth rewriting the whole file for.
    static let compactionThreshold: Int64 = 1024 * 1024

    /// Gives space freed by clearing caches back to the disk: rebuilds the file without its free
    /// pages, then checkpoints and truncates the write-ahead log the rebuild went into. Skipped
    /// when little is free, since it rewrites the whole file and holds the writer meanwhile.
    public func compact() async throws {
        try await writer.writeWithoutTransaction { db in
            let freePages = try Int64.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
            let pageSize = try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 0
            guard freePages * pageSize >= Self.compactionThreshold else { return }
            try db.execute(sql: "VACUUM")
            // Harmless outside WAL mode (in-memory databases).
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    func appliedMigrations() throws -> [String] {
        try writer.read { try Self.migrator.appliedMigrations($0) }
    }
}

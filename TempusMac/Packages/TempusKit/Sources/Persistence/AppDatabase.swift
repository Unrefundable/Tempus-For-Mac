import Foundation
import GRDB
import os

let persistenceLogger = Logger(subsystem: "io.github.unrefundable.TempusMac", category: "Persistence")

/// The app's SQLite database. Mirrors the parts of upstream's Room schema (v24) the Mac needs,
/// scoped per server, plus a response cache for library browsing. See docs/PLAN.md, Phase 2.
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

    func appliedMigrations() throws -> [String] {
        try writer.read { try Self.migrator.appliedMigrations($0) }
    }
}

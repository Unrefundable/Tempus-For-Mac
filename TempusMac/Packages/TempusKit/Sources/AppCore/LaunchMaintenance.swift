import Foundation
import Library
import os
import Persistence

/// Housekeeping at launch: drop cached responses older than the offline window, and listening
/// history older than the longest Home section looks back.
public struct LaunchMaintenance: Sendable {
    /// "Most played this year" is the longest look-back.
    static let historyRetention: TimeInterval = 366 * 24 * 60 * 60
    private static let logger = Logger(subsystem: "io.github.unrefundable.TempusMac", category: "Maintenance")

    private let database: AppDatabase
    private let now: @Sendable () -> Date

    public init(database: AppDatabase, now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database
        self.now = now
    }

    /// Failures are logged and skipped: stale rows only cost space.
    public func run() async {
        let now = now()
        do {
            try await ResponseCache(database: database).prune(olderThan: now - CachedLibrary.maximumCacheAge)
        } catch {
            Self.logger.error("Couldn't prune the response cache: \(error)")
        }
        do {
            try await HistoryStore(database: database).prune(olderThan: now - Self.historyRetention)
        } catch {
            Self.logger.error("Couldn't prune listening history: \(error)")
        }
    }
}

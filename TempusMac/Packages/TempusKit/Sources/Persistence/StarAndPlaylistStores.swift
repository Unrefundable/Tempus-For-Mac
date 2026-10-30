import Foundation
import GRDB

/// What a star or unstar applies to.
public enum StarTarget: Sendable, Hashable {
    case song(String)
    case album(String)
    case artist(String)

    fileprivate var row: (kind: String, id: String) {
        switch self {
        case let .song(id): ("song", id)
        case let .album(id): ("album", id)
        case let .artist(id): ("artist", id)
        }
    }

    fileprivate init?(kind: String, id: String) {
        switch kind {
        case "song": self = .song(id)
        case "album": self = .album(id)
        case "artist": self = .artist(id)
        default: return nil
        }
    }
}

/// A star or unstar made while the server could not be reached (upstream's favorite table).
public struct PendingStar: Sendable, Hashable {
    public let target: StarTarget
    public let isStarred: Bool
    public let createdAt: Date

    public init(target: StarTarget, isStarred: Bool, createdAt: Date) {
        self.target = target
        self.isStarred = isStarred
        self.createdAt = createdAt
    }
}

public struct QueuedStar: Sendable, Hashable, Identifiable {
    public let id: Int64
    public let change: PendingStar
}

/// Stars and unstars waiting to be sent to the server.
public struct PendingStarStore: Sendable {
    private let writer: any DatabaseWriter

    public init(database: AppDatabase) {
        writer = database.writer
    }

    public func enqueue(_ change: PendingStar, server: String) async throws {
        let (kind, id) = change.target.row
        try await writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO pending_star (server_id, kind, target_id, is_starred, created_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [server, kind, id, change.isStarred, change.createdAt]
            )
        }
    }

    /// Oldest first, so replaying them leaves the latest choice in place.
    public func pending(server: String) async throws -> [QueuedStar] {
        try await writer.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM pending_star WHERE server_id = ? ORDER BY id",
                arguments: [server]
            ).compactMap { row in
                guard let target = StarTarget(kind: row["kind"], id: row["target_id"]) else {
                    let kind: String = row["kind"]
                    persistenceLogger.error("Skipping a pending star of unknown kind \(kind, privacy: .public)")
                    return nil
                }
                return QueuedStar(
                    id: row["id"],
                    change: PendingStar(target: target, isStarred: row["is_starred"], createdAt: row["created_at"])
                )
            }
        }
    }

    public func remove(ids: [Int64]) async throws {
        _ = try await writer.write { db in
            try Table("pending_star").filter(ids.contains(Column("id"))).deleteAll(db)
        }
    }
}

/// Playlists pinned to Home.
public struct PinnedPlaylistStore: Sendable {
    private let writer: any DatabaseWriter

    public init(database: AppDatabase) {
        writer = database.writer
    }

    public func pin(_ playlistID: String, server: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO pinned_playlist (server_id, playlist_id) VALUES (?, ?)",
                arguments: [server, playlistID]
            )
        }
    }

    public func unpin(_ playlistID: String, server: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "DELETE FROM pinned_playlist WHERE server_id = ? AND playlist_id = ?",
                arguments: [server, playlistID]
            )
        }
    }

    /// In the order they were pinned.
    public func pinned(server: String) async throws -> [String] {
        try await writer.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT playlist_id FROM pinned_playlist WHERE server_id = ? ORDER BY id",
                arguments: [server]
            )
        }
    }

    public func isPinned(_ playlistID: String, server: String) async throws -> Bool {
        try await pinned(server: server).contains(playlistID)
    }
}

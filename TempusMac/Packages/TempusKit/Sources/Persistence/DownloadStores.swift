import Foundation
import GRDB
import SubsonicAPI

/// A track kept on this Mac. The file lives under the downloads folder; the row names it.
public struct DownloadRecord: Sendable, Hashable, Identifiable {
    public let song: Song
    /// Relative to the server's downloads folder, so the container can move.
    public let fileName: String
    public let size: Int64
    /// The playlist it was downloaded from, for the Downloads view's Playlist grouping. One only,
    /// as upstream.
    public let playlistID: String?
    public let playlistName: String?
    public let downloadedAt: Date

    public var id: String {
        song.id
    }

    public init(
        song: Song,
        fileName: String,
        size: Int64,
        playlistID: String? = nil,
        playlistName: String? = nil,
        downloadedAt: Date
    ) {
        self.song = song
        self.fileName = fileName
        self.size = size
        self.playlistID = playlistID
        self.playlistName = playlistName
        self.downloadedAt = downloadedAt
    }
}

/// Upstream's `download` table, per server.
public struct DownloadStore: Sendable {
    private let writer: any DatabaseWriter

    public init(database: AppDatabase) {
        writer = database.writer
    }

    public func save(_ record: DownloadRecord, server: String) async throws {
        let json = try SongJSON.encode(record.song)
        try await writer.write { db in
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO download
                (server_id, song_id, song, file_name, size, playlist_id, playlist_name, downloaded_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    server, record.song.id, json, record.fileName, record.size,
                    record.playlistID, record.playlistName, record.downloadedAt,
                ]
            )
        }
    }

    /// Newest first.
    public func all(server: String) async throws -> [DownloadRecord] {
        try await writer.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM download WHERE server_id = ? ORDER BY downloaded_at DESC, song_id",
                arguments: [server]
            ).compactMap(Self.record)
        }
    }

    public func record(songID: String, server: String) async throws -> DownloadRecord? {
        try await writer.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM download WHERE server_id = ? AND song_id = ?",
                arguments: [server, songID]
            ).flatMap(Self.record)
        }
    }

    public func delete(songIDs: [String], server: String) async throws {
        guard !songIDs.isEmpty else { return }
        try await writer.write { db in
            for id in songIDs {
                try db.execute(
                    sql: "DELETE FROM download WHERE server_id = ? AND song_id = ?",
                    arguments: [server, id]
                )
            }
        }
    }

    public func deleteAll(server: String) async throws {
        try await writer.write { try $0.execute(sql: "DELETE FROM download WHERE server_id = ?", arguments: [server]) }
    }

    private static func record(_ row: Row) -> DownloadRecord? {
        do {
            return try DownloadRecord(
                song: SongJSON.decode(row["song"]),
                fileName: row["file_name"],
                size: row["size"],
                playlistID: row["playlist_id"],
                playlistName: row["playlist_name"],
                downloadedAt: row["downloaded_at"]
            )
        } catch {
            persistenceLogger.error("Skipping an unreadable download: \(error)")
            return nil
        }
    }
}

/// A playlist kept downloaded: new tracks are fetched when it is opened and at launch.
public struct SyncedPlaylist: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Upstream's `synced_playlist` table, per server.
public struct SyncedPlaylistStore: Sendable {
    private let writer: any DatabaseWriter

    public init(database: AppDatabase) {
        writer = database.writer
    }

    public func add(_ playlist: SyncedPlaylist, server: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO synced_playlist (server_id, playlist_id, name) VALUES (?, ?, ?)",
                arguments: [server, playlist.id, playlist.name]
            )
        }
    }

    public func remove(_ playlistID: String, server: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "DELETE FROM synced_playlist WHERE server_id = ? AND playlist_id = ?",
                arguments: [server, playlistID]
            )
        }
    }

    public func all(server: String) async throws -> [SyncedPlaylist] {
        try await writer.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT playlist_id, name FROM synced_playlist WHERE server_id = ? ORDER BY name",
                arguments: [server]
            ).map { SyncedPlaylist(id: $0["playlist_id"], name: $0["name"]) }
        }
    }
}

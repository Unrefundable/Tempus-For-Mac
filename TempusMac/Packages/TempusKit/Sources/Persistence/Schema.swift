import GRDB

extension AppDatabase {
    /// Never edit a shipped migration; add a new one.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1", migrate: createVersion1)
        migrator.registerMigration("v2", migrate: createVersion2)
        return migrator
    }

    /// Tables holding one server's data. Their rows are deleted with the server, and cleared
    /// when the server's account or address changes (`ServerStore.save`).
    static let perServerTables = [
        "queue", "queue_state", "play_history", "pending_star", "pinned_playlist", "lyrics_cache", "response_cache",
        "download", "synced_playlist",
    ]

    private static func createVersion1(_ db: Database) throws {
        // Passwords and custom headers live in the Keychain, never here.
        try db.create(table: "server") { table in
            table.primaryKey("id", .text)
            table.column("name", .text).notNull()
            table.column("username", .text).notNull()
            table.column("address", .text).notNull()
            table.column("local_address", .text)
            table.column("uses_plaintext_password", .boolean).notNull().defaults(to: false)
            table.column("created_at", .datetime).notNull()
        }
        try db.create(table: "recent_search") { table in
            table.primaryKey("query", .text)
            table.column("searched_at", .datetime).notNull().indexed()
        }
        try createPlaybackTables(db)
        try createCacheTables(db)
    }

    private static func createPlaybackTables(_ db: Database) throws {
        try db.create(table: "queue") { table in
            serverColumn(table)
            table.column("position", .integer).notNull()
            table.column("song", .text).notNull()
            table.primaryKey(["server_id", "position"])
        }
        try db.create(table: "queue_state") { table in
            serverColumn(table).primaryKey()
            table.column("current_index", .integer)
            table.column("position_ms", .integer)
        }
        try db.create(table: "play_history") { table in
            table.autoIncrementedPrimaryKey("id")
            serverColumn(table)
            table.column("song_id", .text).notNull()
            table.column("song", .text).notNull()
            table.column("played_at", .datetime).notNull()
        }
        try db.create(index: "play_history_by_server_time", on: "play_history", columns: ["server_id", "played_at"])
        try db.create(table: "pending_star") { table in
            table.autoIncrementedPrimaryKey("id")
            serverColumn(table)
            table.column("kind", .text).notNull()
            table.column("target_id", .text).notNull()
            table.column("is_starred", .boolean).notNull()
            table.column("created_at", .datetime).notNull()
        }
        // An explicit id keeps pin order stable; rowids of tables without one may change on VACUUM.
        try db.create(table: "pinned_playlist") { table in
            table.autoIncrementedPrimaryKey("id")
            serverColumn(table)
            table.column("playlist_id", .text).notNull()
            table.uniqueKey(["server_id", "playlist_id"])
        }
    }

    private static func createCacheTables(_ db: Database) throws {
        try db.create(table: "lyrics_cache") { table in
            serverColumn(table)
            table.column("song_id", .text).notNull()
            table.column("structured", .text).notNull()
            table.column("plain", .text)
            table.column("updated_at", .datetime).notNull()
            table.primaryKey(["server_id", "song_id"])
        }
        // Upstream keeps local stations across servers, so this table has no server_id.
        try db.create(table: "local_radio_station") { table in
            table.primaryKey("id", .text)
            table.column("name", .text).notNull()
            table.column("stream_url", .text).notNull()
            table.column("home_page_url", .text)
            table.column("cover_art_url", .text)
        }
        try db.create(table: "response_cache") { table in
            serverColumn(table)
            table.column("key", .text).notNull()
            table.column("body", .blob).notNull()
            table.column("fetched_at", .datetime).notNull().indexed()
            table.primaryKey(["server_id", "key"])
        }
    }

    /// Phase 8: downloaded tracks (upstream's `download` table) and playlists kept downloaded
    /// (`synced_playlist`). Files live in Application Support; rows only name them.
    private static func createVersion2(_ db: Database) throws {
        try db.create(table: "download") { table in
            serverColumn(table)
            table.column("song_id", .text).notNull()
            table.column("song", .text).notNull()
            table.column("file_name", .text).notNull()
            table.column("size", .integer).notNull()
            table.column("playlist_id", .text)
            table.column("playlist_name", .text)
            table.column("downloaded_at", .datetime).notNull()
            table.primaryKey(["server_id", "song_id"])
        }
        try db.create(table: "synced_playlist") { table in
            serverColumn(table)
            table.column("playlist_id", .text).notNull()
            table.column("name", .text).notNull()
            table.primaryKey(["server_id", "playlist_id"])
        }
    }

    /// `server_id`, deleted along with its server.
    @discardableResult
    private static func serverColumn(_ table: TableDefinition) -> ColumnDefinition {
        table.column("server_id", .text).notNull().references("server", onDelete: .cascade)
    }
}

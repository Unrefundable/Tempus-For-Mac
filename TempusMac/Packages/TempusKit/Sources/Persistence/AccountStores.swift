import Foundation
import GRDB
import SubsonicAPI

/// A saved server. Its password and custom headers are in the Keychain (`ServerSecretStore`).
public struct ServerProfile: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let username: String
    public let address: ServerAddress
    public let localAddress: ServerAddress?
    public let usesPlaintextPassword: Bool
    public let createdAt: Date

    public init(
        id: String,
        name: String,
        username: String,
        address: ServerAddress,
        localAddress: ServerAddress?,
        usesPlaintextPassword: Bool,
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.username = username
        self.address = address
        self.localAddress = localAddress
        self.usesPlaintextPassword = usesPlaintextPassword
        self.createdAt = createdAt
    }
}

private struct ServerRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "server"

    let id: String
    let name: String
    let username: String
    let address: String
    let localAddress: String?
    let usesPlaintextPassword: Bool
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, username, address
        case localAddress = "local_address"
        case usesPlaintextPassword = "uses_plaintext_password"
        case createdAt = "created_at"
    }

    init(_ profile: ServerProfile) {
        id = profile.id
        name = profile.name
        username = profile.username
        address = profile.address.url.absoluteString
        localAddress = profile.localAddress?.url.absoluteString
        usesPlaintextPassword = profile.usesPlaintextPassword
        createdAt = profile.createdAt
    }

    /// What the server's stored data depends on: who is signed in, and where.
    var identity: [String?] {
        [username, address, localAddress]
    }

    func profile() throws -> ServerProfile {
        try ServerProfile(
            id: id, name: name, username: username,
            address: ServerAddress(address),
            localAddress: localAddress.map(ServerAddress.init),
            usesPlaintextPassword: usesPlaintextPassword, createdAt: createdAt
        )
    }
}

/// Saved servers. Each server's queue, history, stars, pins, lyrics and cached responses belong
/// to it: they are deleted with it, and cleared when its account or address changes.
public struct ServerStore: Sendable {
    private let writer: any DatabaseWriter

    public init(database: AppDatabase) {
        writer = database.writer
    }

    /// Inserts a new server or replaces the one with the same id. A different username, address
    /// or local address means a different account or host, so that server's stored data is cleared.
    public func save(_ profile: ServerProfile) async throws {
        let record = ServerRecord(profile)
        try await writer.write { db in
            if let existing = try ServerRecord.fetchOne(db, key: record.id), existing.identity != record.identity {
                for table in AppDatabase.perServerTables {
                    try Table(table).filter(Column("server_id") == record.id).deleteAll(db)
                }
            }
            try record.save(db)
        }
    }

    /// Oldest first. A row whose address no longer parses is logged and left out.
    public func all() async throws -> [ServerProfile] {
        let records = try await writer.read { db in
            try ServerRecord.order(Column("created_at"), Column("id")).fetchAll(db)
        }
        return records.compactMap { record in
            do {
                return try record.profile()
            } catch {
                persistenceLogger.error("Skipping server \(record.id, privacy: .public): unusable address")
                return nil
            }
        }
    }

    public func server(id: String) async throws -> ServerProfile? {
        try await writer.read { try ServerRecord.fetchOne($0, key: id) }?.profile()
    }

    /// Deletes the server and all of its stored data. Its Keychain secrets are separate:
    /// remove them too with `ServerSecretStore.remove(forServer:)`.
    public func delete(id: String) async throws {
        _ = try await writer.write { try ServerRecord.deleteOne($0, key: id) }
    }
}

/// Searches the user typed, newest first, as upstream's recent-search list.
public struct RecentSearchStore: Sendable {
    public static let limit = 20
    private let writer: any DatabaseWriter

    public init(database: AppDatabase) {
        writer = database.writer
    }

    public func record(_ query: String, at date: Date) async throws {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO recent_search (query, searched_at) VALUES (?, ?)
                ON CONFLICT(query) DO UPDATE SET searched_at = excluded.searched_at
                """,
                arguments: [trimmed, date]
            )
            try db.execute(
                sql: """
                DELETE FROM recent_search WHERE query NOT IN
                (SELECT query FROM recent_search ORDER BY searched_at DESC, query LIMIT ?)
                """,
                arguments: [Self.limit]
            )
        }
    }

    public func recent() async throws -> [String] {
        try await writer
            .read { try String.fetchAll($0, sql: "SELECT query FROM recent_search ORDER BY searched_at DESC, query") }
    }

    public func remove(_ query: String) async throws {
        try await writer.write { try $0.execute(sql: "DELETE FROM recent_search WHERE query = ?", arguments: [query]) }
    }
}

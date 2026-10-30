import Foundation
import GRDB
import SubsonicAPI

/// Lyrics fetched for a song, kept so they show instantly and offline.
public struct CachedLyrics: Sendable, Equatable {
    public let structured: [StructuredLyrics]
    public let plain: String?
    public let updatedAt: Date

    public init(structured: [StructuredLyrics], plain: String?, updatedAt: Date) {
        self.structured = structured
        self.plain = plain
        self.updatedAt = updatedAt
    }
}

/// Lyrics per server and song. An unreadable entry is treated as missing.
public struct LyricsStore: Sendable {
    private let writer: any DatabaseWriter

    public init(database: AppDatabase) {
        writer = database.writer
    }

    public func save(_ lyrics: CachedLyrics, song: String, server: String) async throws {
        let structured = try SongJSON.text(JSONEncoder().encode(lyrics.structured))
        try await writer.write { db in
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO lyrics_cache (server_id, song_id, structured, plain, updated_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [server, song, structured, lyrics.plain, lyrics.updatedAt]
            )
        }
    }

    public func lyrics(song: String, server: String) async throws -> CachedLyrics? {
        try await writer.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT structured, plain, updated_at FROM lyrics_cache WHERE server_id = ? AND song_id = ?",
                arguments: [server, song]
            ).flatMap { row -> CachedLyrics? in
                let structured: String = row["structured"]
                guard let lines = try? JSONDecoder().decode([StructuredLyrics].self, from: Data(structured.utf8)) else {
                    persistenceLogger.error("Ignoring unreadable cached lyrics")
                    return nil
                }
                return CachedLyrics(structured: lines, plain: row["plain"], updatedAt: row["updated_at"])
            }
        }
    }
}

/// A radio station kept on this Mac, shown with every server (upstream's "Local" stations).
public struct LocalRadioStation: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let streamURL: URL
    public let homePageURL: URL?
    public let coverArtURL: URL?

    public init(id: String, name: String, streamURL: URL, homePageURL: URL?, coverArtURL: URL?) {
        self.id = id
        self.name = name
        self.streamURL = streamURL
        self.homePageURL = homePageURL
        self.coverArtURL = coverArtURL
    }
}

private struct LocalRadioRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "local_radio_station"

    let id: String
    let name: String
    let streamURL: URL
    let homePageURL: URL?
    let coverArtURL: URL?

    enum CodingKeys: String, CodingKey {
        case id, name
        case streamURL = "stream_url"
        case homePageURL = "home_page_url"
        case coverArtURL = "cover_art_url"
    }

    init(_ station: LocalRadioStation) {
        id = station.id
        name = station.name
        streamURL = station.streamURL
        homePageURL = station.homePageURL
        coverArtURL = station.coverArtURL
    }

    var station: LocalRadioStation {
        LocalRadioStation(id: id, name: name, streamURL: streamURL, homePageURL: homePageURL, coverArtURL: coverArtURL)
    }
}

/// Radio stations kept on this Mac rather than on a server.
public struct LocalRadioStore: Sendable {
    private let writer: any DatabaseWriter

    public init(database: AppDatabase) {
        writer = database.writer
    }

    /// Adds the station or replaces the one with the same id.
    public func save(_ station: LocalRadioStation) async throws {
        try await writer.write { try LocalRadioRecord(station).save($0) }
    }

    /// Sorted by name, ignoring case.
    public func all() async throws -> [LocalRadioStation] {
        try await writer.read { db in
            try LocalRadioRecord.fetchAll(db, sql: "SELECT * FROM local_radio_station ORDER BY name COLLATE NOCASE")
        }.map(\.station)
    }

    public func delete(id: String) async throws {
        _ = try await writer.write { try LocalRadioRecord.deleteOne($0, key: id) }
    }
}

/// A response body and when it was fetched.
public struct CachedResponse: Sendable, Equatable {
    public let data: Data
    public let fetchedAt: Date
}

/// Raw server responses for library browsing, so screens show the last known data at once and
/// work offline. Plays the role of upstream's OkHttp response cache. Only cache read-only
/// requests, keyed by `SubsonicRequest.cacheKey`; call `prune(olderThan:)` at launch.
public struct ResponseCache: Sendable {
    private let writer: any DatabaseWriter

    public init(database: AppDatabase) {
        writer = database.writer
    }

    public func store(_ data: Data, key: String, server: String, fetchedAt: Date) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO response_cache (server_id, key, body, fetched_at) VALUES (?, ?, ?, ?)",
                arguments: [server, key, data, fetchedAt]
            )
        }
    }

    public func entry(key: String, server: String) async throws -> CachedResponse? {
        try await writer.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT body, fetched_at FROM response_cache WHERE server_id = ? AND key = ?",
                arguments: [server, key]
            ).map { CachedResponse(data: $0["body"], fetchedAt: $0["fetched_at"]) }
        }
    }

    public func prune(olderThan cutoff: Date) async throws {
        try await writer.write { try $0.execute(
            sql: "DELETE FROM response_cache WHERE fetched_at < ?",
            arguments: [cutoff]
        ) }
    }

    public func clear(server: String) async throws {
        try await writer.write { try $0.execute(
            sql: "DELETE FROM response_cache WHERE server_id = ?",
            arguments: [server]
        ) }
    }
}

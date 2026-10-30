import Foundation
@testable import Persistence
import SubsonicAPI

/// A song as a server would send it, decoded through the real model.
func song(_ id: String, title: String? = nil, artist: String = "Artist") throws -> Song {
    let json = #"{"id":"\#(id)","title":"\#(title ?? "Song \(id)")","artist":"\#(artist)","isDir":false}"#
    return try JSONDecoder().decode(Song.self, from: Data(json.utf8))
}

/// A fixed moment, so tests never depend on the clock.
func date(_ secondsSince2024: TimeInterval) -> Date {
    Date(timeIntervalSince1970: 1_704_067_200 + secondsSince2024)
}

func emptyDatabase() throws -> AppDatabase {
    try AppDatabase.inMemory()
}

/// A database with the servers that per-server rows in these tests belong to.
func seededDatabase(servers: [String] = ["s", "other", "x", "srv-1"]) throws -> AppDatabase {
    let database = try emptyDatabase()
    try database.writer.write { db in
        for id in servers {
            try db.execute(
                sql: """
                INSERT INTO server (id, name, username, address, uses_plaintext_password, created_at)
                VALUES (?, ?, 'alice', 'https://music.example.com', 0, ?)
                """,
                arguments: [id, id, date(0)]
            )
        }
    }
    return database
}

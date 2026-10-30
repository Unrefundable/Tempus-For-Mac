import Foundation
import SubsonicAPI

/// Songs are stored as their Subsonic JSON, so they decode through the same lenient path as
/// server responses and survive model changes without a migration.
enum SongJSON {
    static func encode(_ song: Song) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try text(encoder.encode(song))
    }

    static func decode(_ text: String) throws -> Song {
        try JSONDecoder().decode(Song.self, from: Data(text.utf8))
    }

    /// JSONEncoder always writes UTF-8; anything else means the data is not ours.
    static func text(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.coderInvalidValue)
        }
        return text
    }
}

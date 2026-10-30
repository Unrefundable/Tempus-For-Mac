import Foundation

/// Plain lyrics from the classic `getLyrics` (artist + title lookup).
public struct Lyrics: Decodable, Sendable, Hashable {
    public let artist: String?
    public let title: String?
    public let text: String?

    private enum CodingKeys: String, CodingKey {
        case artist, title
        case text = "value"
    }
}

/// OpenSubsonic `getLyricsBySongId` lyrics, synced or not, one entry per language.
public struct StructuredLyrics: Decodable, Sendable, Hashable {
    public let displayArtist: String?
    public let displayTitle: String?
    /// ISO 639 code, or `xxx` when unknown.
    public let lang: String?
    /// Milliseconds to add to each line's start.
    public let offset: Int?
    public let isSynced: Bool
    @OneOrMany public var lines: [LyricLine]

    private enum CodingKeys: String, CodingKey {
        case displayArtist, displayTitle, lang, offset
        case isSynced = "synced"
        case lines = "line"
    }
}

public struct LyricLine: Decodable, Sendable, Hashable {
    /// Milliseconds; nil for unsynced lyrics.
    public let start: Int?
    public let value: String
}

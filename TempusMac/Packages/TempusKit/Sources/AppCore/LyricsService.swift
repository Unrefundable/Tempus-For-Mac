import Foundation
import os
import Persistence
import SubsonicAPI

/// What the lyrics panel shows, in upstream's order of preference: synced, then plain, then nothing.
public enum LyricsContent: Sendable, Equatable {
    case none
    case plain(String)
    case synced([Line])

    public struct Line: Sendable, Hashable {
        /// Seconds into the track, the lyrics' offset included.
        public let start: TimeInterval
        public let text: String

        public init(start: TimeInterval, text: String) {
            self.start = start
            self.text = text
        }
    }

    init(structured: [StructuredLyrics], plain: String?) {
        if let synced = structured.first(where: { $0.isSynced && !$0.lines.isEmpty }) {
            let offset = TimeInterval(synced.offset ?? 0)
            self = .synced(synced.lines.map { line in
                Line(start: (TimeInterval(line.start ?? 0) + offset) / 1000, text: line.value)
            })
        } else if let unsynced = structured.first(where: { !$0.lines.isEmpty }) {
            self = .plain(unsynced.lines.map(\.value).joined(separator: "\n"))
        } else if let plain, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self = .plain(plain)
        } else {
            self = .none
        }
    }

    /// The line being sung at `position`: the last one that has started, nil before the first.
    public static func currentLineIndex(in lines: [Line], at position: TimeInterval) -> Int? {
        lines.lastIndex { $0.start <= position }
    }
}

/// Lyrics for the playing song: from the cache when there, else from the server, then cached.
public struct LyricsService: Sendable {
    private static let logger = Logger(subsystem: "io.github.unrefundable.TempusMac", category: "Lyrics")

    private let client: SubsonicClient
    private let store: LyricsStore
    private let serverID: String
    private let supportsSongLyrics: Bool
    private let now: @Sendable () -> Date

    /// - Parameter supportsSongLyrics: the server is OpenSubsonic, so `getLyricsBySongId` may work.
    public init(
        client: SubsonicClient,
        store: LyricsStore,
        serverID: String,
        supportsSongLyrics: Bool,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.store = store
        self.serverID = serverID
        self.supportsSongLyrics = supportsSongLyrics
        self.now = now
    }

    /// Only answers that came from the server are cached, "no lyrics" included; a failed or
    /// cancelled lookup is thrown, so it's tried again next time.
    public func lyrics(for song: Song) async throws(SubsonicError) -> LyricsContent {
        do {
            if let cached = try await store.lyrics(song: song.id, server: serverID) {
                return LyricsContent(structured: cached.structured, plain: cached.plain)
            }
        } catch {
            Self.logger.error("Couldn't read cached lyrics: \(error)")
        }
        var structured: [StructuredLyrics] = []
        var songLyricsError: SubsonicError?
        if supportsSongLyrics {
            do throws(SubsonicError) {
                structured = try await client.send(.lyrics(songID: song.id))
            } catch .cancelled {
                throw .cancelled
            } catch {
                Self.logger.notice("getLyricsBySongId failed, trying getLyrics: \(error)")
                songLyricsError = error
            }
        }
        var plain: String?
        if structured.allSatisfy(\.lines.isEmpty) {
            if let artist = song.artist, let title = song.title {
                plain = try await client.send(.lyrics(artist: artist, title: title))?.text
            } else if let songLyricsError {
                throw songLyricsError
            }
        }
        do {
            try await store.save(
                CachedLyrics(structured: structured, plain: plain, updatedAt: now()),
                song: song.id,
                server: serverID
            )
        } catch {
            Self.logger.error("Couldn't cache lyrics: \(error)")
        }
        return LyricsContent(structured: structured, plain: plain)
    }
}

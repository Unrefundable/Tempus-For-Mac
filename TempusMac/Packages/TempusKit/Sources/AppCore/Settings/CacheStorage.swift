import Foundation
import Observation
import os
import Persistence

/// What Tempus keeps on this Mac only to be quicker or work offline. All of it can be fetched
/// again from the server, so clearing it loses nothing. Downloads aren't a cache: Settings lists
/// them beside these, but they are removed through `DownloadManager`.
public enum CacheCategory: String, CaseIterable, Sendable, Identifiable {
    /// Cover images, every server and size.
    case artwork
    /// Saved server responses that let library screens draw at once and offline.
    case library
    /// Lyrics fetched for songs played, and the lyrics search index.
    case lyrics

    public var id: Self {
        self
    }

    public var title: String {
        switch self {
        case .artwork: "Cover art"
        case .library: "Library data"
        case .lyrics: "Lyrics"
        }
    }

    public var summary: String {
        switch self {
        case .artwork: "Album, artist and playlist images."
        case .library: "Albums, artists and playlists saved so screens open at once and work offline."
        case .lyrics: "Lyrics of songs you've played, and the lyrics that lyrics search looks through."
        }
    }
}

/// How many bytes each cache takes.
public struct CacheUsage: Sendable, Equatable {
    private let bytes: [CacheCategory: Int64]

    public init(_ bytes: [CacheCategory: Int64]) {
        self.bytes = bytes
    }

    public func bytes(for category: CacheCategory) -> Int64 {
        bytes[category] ?? 0
    }

    public var totalBytes: Int64 {
        bytes.values.reduce(0, +)
    }
}

/// Measures and clears the caches every server shares. File and database work runs off the main actor.
public struct CacheStorage: Sendable {
    static let logger = Logger(subsystem: "io.github.unrefundable.TempusMac", category: "CacheStorage")

    private let database: AppDatabase
    private let artworkCaches: ArtworkCaches

    public init(database: AppDatabase, artworkCaches: ArtworkCaches) {
        self.database = database
        self.artworkCaches = artworkCaches
    }

    @concurrent
    public func usage() async throws -> CacheUsage {
        let artwork = artworkCaches.diskBytes()
        let library = try await ResponseCache(database: database).totalBytes()
        let lyrics = try await LyricsStore(database: database).totalBytes()
            + LyricsIndexStore(database: database).totalBytes()
        return CacheUsage([.artwork: artwork, .library: library, .lyrics: lyrics])
    }

    /// Empties `categories`, each on its own so one failing doesn't stop the rest, then gives the
    /// database's freed space back to the disk. Throws the first failure once all were tried.
    @concurrent
    public func clear(_ categories: Set<CacheCategory>) async throws {
        var firstFailure: (any Error)?
        for category in CacheCategory.allCases where categories.contains(category) {
            do {
                try await clear(category)
            } catch {
                Self.logger.error("Couldn't clear \(category.rawValue, privacy: .public): \(error)")
                firstFailure = firstFailure ?? error
            }
        }
        if !categories.isDisjoint(with: [.library, .lyrics]) {
            do {
                try await database.compact()
            } catch {
                // The rows are gone either way; an uncompacted file only keeps its size.
                Self.logger.error("Couldn't compact the database: \(error)")
            }
        }
        if let firstFailure {
            throw firstFailure
        }
    }

    private func clear(_ category: CacheCategory) async throws {
        switch category {
        case .artwork: artworkCaches.removeAll()
        case .library: try await ResponseCache(database: database).clearAll()
        case .lyrics:
            try await LyricsStore(database: database).clearAll()
            try await LyricsIndexStore(database: database).clearAll()
        }
    }
}

public extension AppModel {
    /// The caches every server shares, for Settings' Storage pane.
    var cacheStorage: CacheStorage {
        CacheStorage(database: environment.database, artworkCaches: environment.artworkCaches)
    }
}

/// The Settings pane's view of the caches: what each takes, and clearing them.
@MainActor
@Observable
public final class CacheViewer {
    /// Nil until first measured.
    public private(set) var usage: CacheUsage?
    /// The caches being cleared now.
    public private(set) var clearing: Set<CacheCategory> = []
    /// Why the last measure or clear failed. Safe to show.
    public private(set) var errorMessage: String?

    @ObservationIgnored private let storage: CacheStorage
    /// Bumped by each measure, so a slow one overtaken by a newer one is dropped.
    @ObservationIgnored private var measurement = 0

    public init(storage: CacheStorage) {
        self.storage = storage
    }

    public func refresh() async {
        measurement += 1
        let current = measurement
        do {
            let measured = try await storage.usage()
            guard current == measurement else { return }
            usage = measured
            errorMessage = nil
        } catch {
            guard current == measurement else { return }
            CacheStorage.logger.error("Couldn't measure the caches: \(error)")
            errorMessage = "Couldn't work out how much space the caches use."
        }
    }

    /// Clears `categories` and measures again. Caches already being cleared are skipped.
    public func clear(_ categories: Set<CacheCategory>) async {
        let asked = categories.subtracting(clearing)
        guard !asked.isEmpty else { return }
        clearing.formUnion(asked)
        defer { clearing.subtract(asked) }
        do {
            try await storage.clear(asked)
        } catch {
            // `CacheStorage.clear` has logged each failure.
            await refresh()
            errorMessage = "Couldn't clear the cache. Try again."
            return
        }
        await refresh()
    }
}

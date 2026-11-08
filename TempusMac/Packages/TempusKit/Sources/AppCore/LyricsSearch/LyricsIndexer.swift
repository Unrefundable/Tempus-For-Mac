import Foundation
import os
import Persistence
import SubsonicAPI

/// How far a sync has got through the songs it fetches lyrics for.
public struct LyricsIndexProgress: Sendable, Equatable {
    public let done: Int
    public let total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }
}

enum LyricsIndexError: Error {
    /// Lyrics requests kept failing to reach the server; the rest wait for the next check.
    case serverUnreachable
    /// The server listed no songs while the index has some: more likely a server that doesn't
    /// list everything for an empty search than an emptied library, so nothing is removed.
    case emptyListing
}

/// Brings one server's lyrics search index up to date: lists every song, fetches lyrics only for
/// songs that are new or whose file changed, asks again now and then about songs without lyrics,
/// and drops songs the server no longer has. Lyrics are saved as they arrive, so an interrupted
/// sync never fetches them again.
///
/// A song with lyrics is fetched again only when its file's size or path changes, which embedding
/// new lyrics does; an edited lyrics file beside it is picked up after Storage's Lyrics is cleared.
struct LyricsIndexer: Sendable {
    static let logger = Logger(subsystem: "io.github.unrefundable.TempusMac", category: "LyricsSearch")

    /// How long a song without lyrics waits before it's asked about again, for lyrics files added
    /// beside it later. Also how often the whole library is listed when the server doesn't say
    /// when it last scanned.
    static let recheckInterval: TimeInterval = 7 * 24 * 60 * 60
    /// How long songs whose lyrics failed to load wait before the next try.
    static let retryAfterFailures: TimeInterval = 60 * 60
    /// Songs per `search3` page.
    static let defaultPageSize = 500
    /// Lyrics requests in flight at once: quick to finish, light on the server.
    static let defaultConcurrentFetches = 4
    /// Entries written per transaction while fetching.
    static let saveBatchSize = 50
    /// Requests in a row that couldn't reach the server before a sync gives up.
    static let unreachableBeforeGivingUp = 20
    /// Progress is reported every this many songs, and at the end.
    static let progressStep = 20
    /// A bound on listing, against a server that ignores the offset and repeats a page.
    static let maxPages = 2000

    let client: SubsonicClient
    let lyrics: LyricsService
    let index: LyricsIndexStore
    let serverID: String
    let pageSize: Int
    let concurrentFetches: Int
    let now: @Sendable () -> Date

    init(
        client: SubsonicClient,
        lyrics: LyricsService,
        index: LyricsIndexStore,
        serverID: String,
        pageSize: Int = defaultPageSize,
        concurrentFetches: Int = defaultConcurrentFetches,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.lyrics = lyrics
        self.index = index
        self.serverID = serverID
        self.pageSize = pageSize
        self.concurrentFetches = concurrentFetches
        self.now = now
    }

    /// Syncs when the server has finished a scan since the last sync, or a sync is due by time.
    /// Waits while the server is scanning, since the library is changing.
    func syncIfNeeded(progress: @escaping @Sendable (LyricsIndexProgress) async -> Void) async throws {
        let state = try await index.state(server: serverID)
        guard let status = try await scanStatus() else {
            // Without the server's word, only a first sync goes ahead; the rest wait.
            if state == nil {
                try await sync(lastScan: nil, before: nil, progress: progress)
            }
            return
        }
        guard !status.isScanning else { return }
        if let state, state.lastScan == status.lastScan,
           now().timeIntervalSince(state.syncedAt) < Self.recheckInterval
        {
            return
        }
        try await sync(lastScan: status.lastScan, before: status, progress: progress)
    }

    /// - Parameter before: the scan status the sync started from, compared again once the library
    ///   is listed; nil when the server didn't give one.
    private func sync(
        lastScan: String?,
        before: ScanStatus?,
        progress: @escaping @Sendable (LyricsIndexProgress) async -> Void
    ) async throws {
        let indexed = try await index.indexedSongs(server: serverID)
        let checkTime = now()
        let listing = try await listSongs { Self.needsFetch($0, indexed: indexed[$0.id], now: checkTime) }
        guard !listing.ids.isEmpty || indexed.isEmpty else { throw LyricsIndexError.emptyListing }
        if let before, try await scanStatus().map({ $0.isScanning || $0.lastScan != before.lastScan }) ?? true {
            Self.logger.info("The library changed while it was listed; syncing lyrics at the next check")
            return
        }
        let gone = Set(indexed.keys).subtracting(listing.ids)
        try await index.remove(songs: gone, server: serverID)
        let failures = try await fetchAndSave(listing.stale, progress: progress)
        Self.logger.info(
            "Lyrics index synced: \(listing.stale.count) fetched, \(failures) failed, \(gone.count) removed"
        )
        // After failures the next sync is due sooner, to try those songs again.
        let syncedAt = failures == 0 ? now() : now().addingTimeInterval(Self.retryAfterFailures - Self.recheckInterval)
        try await index.setState(LyricsIndexState(lastScan: lastScan, syncedAt: syncedAt), server: serverID)
    }

    /// Whether `song`'s lyrics need fetching: new, its file changed, or without lyrics for a while.
    static func needsFetch(_ song: Song, indexed: IndexedSong?, now: Date) -> Bool {
        guard let indexed else { return true }
        if indexed.fingerprint != fingerprint(of: song) {
            return true
        }
        return !indexed.hasLyrics && now.timeIntervalSince(indexed.checkedAt) >= recheckInterval
    }

    /// Changes when the file does: embedding lyrics in a file changes its size.
    static func fingerprint(of song: Song) -> String {
        "\(song.size ?? -1)|\(song.path ?? "")"
    }

    /// Nil when the server couldn't say.
    private func scanStatus() async throws -> ScanStatus? {
        do throws(SubsonicError) {
            return try await client.send(.scanStatus)
        } catch .cancelled {
            throw CancellationError()
        } catch {
            Self.logger.notice("No scan status from the server: \(error)")
            return nil
        }
    }

    /// Every song's ID, and the songs `isStale` picks, page by page. Only the stale songs are kept
    /// whole, so a large library isn't held in memory. Pages continue until one comes back empty,
    /// since a server may send fewer songs than asked for.
    private func listSongs(where isStale: (Song) -> Bool) async throws -> (ids: Set<String>, stale: [Song]) {
        var ids: Set<String> = []
        var stale: [Song] = []
        var offset = 0
        for page in 0 ..< Self.maxPages {
            let batch = try await send(.allSongs(offset: offset, count: pageSize)).songs
            offset += batch.count
            let new = batch.filter { ids.insert($0.id).inserted }
            stale += new.filter(isStale)
            // An empty page is the end; a page of songs already seen means the server ignores
            // the offset.
            if new.isEmpty {
                break
            }
            if page == Self.maxPages - 1 {
                Self.logger.error("Stopped listing songs after \(Self.maxPages) pages")
            }
        }
        return (ids, stale)
    }

    /// Fetches lyrics for `songs` a few at a time, saving as they arrive. Returns how many failed.
    private func fetchAndSave(
        _ songs: [Song],
        progress: @escaping @Sendable (LyricsIndexProgress) async -> Void
    ) async throws -> Int {
        guard !songs.isEmpty else { return 0 }
        await progress(LyricsIndexProgress(done: 0, total: songs.count))
        var tally = FetchTally()
        var pending: [LyricsIndexEntry] = []
        do {
            try await withThrowingTaskGroup(of: FetchOutcome.self) { group in
                var remaining = songs.makeIterator()
                for _ in 0 ..< concurrentFetches {
                    if let song = remaining.next() {
                        group.addTask { try await outcome(for: song) }
                    }
                }
                while let outcome = try await group.next() {
                    if case let .indexed(entry) = outcome {
                        pending.append(entry)
                    }
                    try tally.record(outcome)
                    if pending.count >= Self.saveBatchSize {
                        try await index.save(pending, server: serverID)
                        pending = []
                    }
                    if tally.done % Self.progressStep == 0 || tally.done == songs.count {
                        await progress(LyricsIndexProgress(done: tally.done, total: songs.count))
                    }
                    if let song = remaining.next() {
                        group.addTask { try await self.outcome(for: song) }
                    }
                }
            }
        } catch {
            // What arrived before the sync ended is kept, so it isn't fetched again.
            try? await index.save(pending, server: serverID)
            throw error
        }
        try await index.save(pending, server: serverID)
        return tally.failures
    }

    private func outcome(for song: Song) async throws -> FetchOutcome {
        do throws(SubsonicError) {
            let content = try await lyrics.fetch(for: song)
            return .indexed(LyricsIndexEntry(
                song: song, fingerprint: Self.fingerprint(of: song), lyrics: content.text, checkedAt: now()
            ))
        } catch .cancelled {
            throw CancellationError()
        } catch {
            Self.logger.notice("Couldn't load lyrics to index a song: \(error)")
            return .failed(isUnreachable: error.isUnreachable)
        }
    }

    private func send<Response>(_ request: SubsonicRequest<Response>) async throws -> Response {
        do throws(SubsonicError) {
            return try await client.send(request)
        } catch .cancelled {
            throw CancellationError()
        }
    }
}

/// One song's lyrics fetched, or why not.
private enum FetchOutcome {
    case indexed(LyricsIndexEntry)
    /// Tried again next sync. `isUnreachable`: the request never got an answer from the server,
    /// rather than the server refusing this one song.
    case failed(isUnreachable: Bool)
}

private extension SubsonicError {
    /// The server couldn't be reached or isn't working, as opposed to an error about one request.
    var isUnreachable: Bool {
        switch self {
        case .transport, .httpStatus: true
        default: false
        }
    }
}

/// Songs fetched and failed so far, and requests in a row that couldn't reach the server.
private struct FetchTally {
    private(set) var done = 0
    private(set) var failures = 0
    private var unreachableInARow = 0

    mutating func record(_ outcome: FetchOutcome) throws {
        done += 1
        guard case let .failed(isUnreachable) = outcome else {
            unreachableInARow = 0
            return
        }
        failures += 1
        unreachableInARow = isUnreachable ? unreachableInARow + 1 : 0
        if unreachableInARow >= LyricsIndexer.unreachableBeforeGivingUp {
            throw LyricsIndexError.serverUnreachable
        }
    }
}

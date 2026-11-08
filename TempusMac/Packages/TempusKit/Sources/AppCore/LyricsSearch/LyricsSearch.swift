import Foundation
import Observation
import Persistence
import SubsonicAPI

/// Lyrics search for one server. Only while the user has turned it on in Settings does it keep the
/// index up to date: a sync at once, then a cheap check of the server's last scan every so often.
/// Turned off, nothing is fetched and nothing is found, but the index stays until cleared in
/// Settings' Storage tab, so turning it back on only fetches what changed meanwhile.
@MainActor
@Observable
public final class LyricsSearch {
    /// How often a server is asked whether it has scanned since the last sync.
    static let checkInterval: Duration = .seconds(15 * 60)

    /// The sync fetching lyrics now; nil when none is.
    public private(set) var progress: LyricsIndexProgress?

    /// Whether the setting is on, so searches look at lyrics.
    public var isEnabled: Bool {
        settings.searchesLyrics
    }

    /// The background syncing is running.
    var isSyncing: Bool {
        task != nil
    }

    @ObservationIgnored private let indexer: LyricsIndexer
    @ObservationIgnored private let index: LyricsIndexStore
    @ObservationIgnored private let serverID: String
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let isOffline: Bool
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Syncing waits while the index is being cleared (`pausing`).
    @ObservationIgnored private var isPaused = false

    init(indexer: LyricsIndexer, index: LyricsIndexStore, serverID: String, settings: AppSettings, isOffline: Bool) {
        self.indexer = indexer
        self.index = index
        self.serverID = serverID
        self.settings = settings
        self.isOffline = isOffline
    }

    /// Starts or stops syncing to match the setting. An offline session never syncs; coming back
    /// online makes a new session. A sync stopped here may finish the request it's on; anything it
    /// saves is still right.
    public func update() {
        guard settings.searchesLyrics, !isOffline, !isPaused else {
            task?.cancel()
            task = nil
            progress = nil
            return
        }
        guard task == nil else { return }
        task = Task { [weak self] in
            // `self` only while a check runs, so the sleep doesn't keep the owner alive, and the
            // loop ends once the owner is gone.
            while !Task.isCancelled, await self?.syncNow() != nil {
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    /// Stops syncing and waits for the sync under way to wind down, so nothing more is written.
    public func stop() async {
        let running = task
        running?.cancel()
        task = nil
        progress = nil
        await running?.value
    }

    /// Stops syncing while `work` runs, such as clearing the index, then starts again if the
    /// setting is on. Turning the setting on meanwhile waits for the end.
    public func pausing(_ work: () async -> Void) async {
        isPaused = true
        await stop()
        await work()
        isPaused = false
        update()
    }

    /// One check, and a sync if the server changed. Failures are logged and retried next check.
    func syncNow() async {
        do {
            try await indexer.syncIfNeeded { [weak self] progress in
                // A stopped sync's last report would cover the one that replaced it.
                guard !Task.isCancelled else { return }
                await self?.show(progress)
            }
        } catch is CancellationError {
            return
        } catch {
            LyricsIndexer.logger.error("Lyrics index sync failed: \(error)")
        }
        if !Task.isCancelled {
            progress = nil
        }
    }

    /// Songs whose lyrics match `query`, best first, each with its best line. Empty while off,
    /// and when the search was cancelled for a newer one.
    public func search(_ query: String) async -> [LyricsSearchMatch] {
        guard settings.searchesLyrics else { return [] }
        do {
            let found = try await index.search(query, server: serverID)
            return await Self.lines(for: found, query: query)
        } catch is CancellationError {
            return []
        } catch {
            LyricsIndexer.logger.error("Lyrics search failed: \(error)")
            return []
        }
    }

    private func show(_ progress: LyricsIndexProgress) {
        // A finished count is no progress to show.
        self.progress = progress.done < progress.total ? progress : nil
    }

    /// Off the main actor: folding every line's words is quick but not free.
    @concurrent
    private static func lines(for found: [LyricsIndexMatch], query: String) async -> [LyricsSearchMatch] {
        found.map { match in
            let best = LyricsSearchMatch.bestLine(in: match.lyrics, for: query)
            return LyricsSearchMatch(song: match.song, line: best?.line ?? "", highlights: best?.highlights ?? [])
        }
    }
}

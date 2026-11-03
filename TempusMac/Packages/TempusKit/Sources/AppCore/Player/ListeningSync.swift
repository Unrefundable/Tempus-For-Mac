import Foundation
import Observation
import os
import Persistence
import Playback
import SubsonicAPI

/// Which tracks keep their spot after you move on (upstream's resume policy): podcast episodes,
/// audiobooks, and music longer than 10 minutes.
public enum ResumePolicy {
    public static let longTrack: TimeInterval = 10 * 60
    /// A track left this close to its end counts as played through, and its bookmark goes.
    static let finishedWithin: TimeInterval = 10

    public static func keepsSpot(_ song: Song) -> Bool {
        switch song.type {
        case "podcast", "audiobook": true
        case "radio": false
        default: TimeInterval(song.duration ?? 0) > longTrack
        }
    }

    static func isFinished(position: TimeInterval, duration: TimeInterval) -> Bool {
        duration > 0 && position >= duration - finishedWithin
    }
}

/// Tells the server what plays (scrobbling) and records plays for Home's history sections.
/// Consumes `PlayerController.events`, its only consumer.
@MainActor
final class Scrobbler {
    private static let logger = Logger(subsystem: "io.github.unrefundable.TempusMac", category: "Scrobbler")

    private let client: SubsonicClient
    private let history: HistoryStore
    private let serverID: String
    private let settings: AppSettings

    init(client: SubsonicClient, history: HistoryStore, serverID: String, settings: AppSettings) {
        self.client = client
        self.history = history
        self.serverID = serverID
        self.settings = settings
    }

    /// Runs until the player's event stream ends.
    func run(events: AsyncStream<PlaybackEvent>) async {
        for await event in events {
            await handle(event)
        }
    }

    func handle(_ event: PlaybackEvent) async {
        switch event {
        case let .nowPlaying(song):
            guard settings.scrobbles else { return }
            await send(.scrobble(id: song.id, submission: false))
        case let .played(song, date):
            do {
                try await history.recordPlay(song, server: serverID, at: date)
            } catch {
                Self.logger.error("Couldn't record a play: \(error)")
            }
            guard settings.scrobbles else { return }
            // Upstream doesn't retry a scrobble that doesn't reach the server.
            await send(.scrobble(id: song.id, time: date, submission: true))
        }
    }

    private func send(_ request: SubsonicRequest<EmptyResponse>) async {
        do {
            _ = try await client.send(request)
        } catch {
            Self.logger.notice("Scrobble not sent: \(error.userMessage, privacy: .public)")
        }
    }
}

/// Keeps the listening position on the server: bookmarks for tracks that keep their spot
/// (Continue Listening) and, when turned on, the play queue (upstream's "Sync play queue").
/// Saves when playback pauses, when the track changes, and periodically while playing.
@MainActor
public final class ListeningSync {
    static let bookmarkInterval: TimeInterval = 15
    static let queueInterval: TimeInterval = 30
    static let sampleInterval = Duration.seconds(1)
    static let pendingLimit = 16
    private static let logger = Logger(subsystem: "io.github.unrefundable.TempusMac", category: "ListeningSync")

    private let player: PlayerController
    private let client: SubsonicClient
    private let settings: AppSettings
    private let now: @Sendable () -> Date

    /// The song last seen playing and how far it got, so a switch can save the old one's spot.
    private struct Tracked {
        let item: QueueItem.ID
        let song: Song
        let position: TimeInterval
        let duration: TimeInterval
    }

    private var tracked: Tracked?
    private var lastStatus = PlaybackStatus.stopped
    private var lastBookmarkSave = Date.distantPast
    private var lastQueueSave = Date.distantPast
    private var sampler: Task<Void, Never>?
    /// Saves still on their way, so tests (and quitting) can wait for them.
    private var pending: [Task<Void, Never>] = []

    init(player: PlayerController, client: SubsonicClient, settings: AppSettings, now: @escaping @Sendable () -> Date) {
        self.player = player
        self.client = client
        self.settings = settings
        self.now = now
    }

    /// Starts watching the player and sampling its position.
    func start() {
        lastStatus = player.status
        sample()
        observe()
        sampler = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.sampleInterval)
                self?.tick()
            }
        }
    }

    func stop() {
        sampler?.cancel()
        sampler = nil
    }

    /// Waits for saves already sent.
    func settled() async {
        let tasks = pending
        pending = []
        for task in tasks {
            await task.value
        }
    }

    // MARK: Watching the player

    private func observe() {
        withObservationTracking {
            _ = player.status
            _ = player.queue.currentID
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.sampler != nil else { return }
                self.playerChanged()
                self.observe()
            }
        }
    }

    /// The track or the status changed.
    func playerChanged() {
        sample()
        let status = player.status
        if status == .paused, lastStatus.isActive {
            sample()
            if let tracked {
                saveBookmark(tracked.song, at: tracked.position)
            }
            saveQueue()
        }
        lastStatus = status
        sample()
    }

    /// Saves the spot and the queue now, as before quitting: upstream saves on pause, which a
    /// quit skips.
    func saveNow() {
        sample()
        if let tracked {
            saveBookmark(tracked.song, at: tracked.position)
        }
        saveQueue()
    }

    /// Once a second: note the position, and save on the intervals while playing.
    func tick() {
        sample()
        guard player.status == .playing, let tracked else { return }
        let date = now()
        if date.timeIntervalSince(lastBookmarkSave) >= Self.bookmarkInterval {
            saveBookmark(tracked.song, at: tracked.position)
        }
        if date.timeIntervalSince(lastQueueSave) >= Self.queueInterval {
            saveQueue()
        }
    }

    /// Notes the current track and position. A track that is no longer current is left first,
    /// whichever of the tick and the observer sees the change.
    private func sample() {
        let current = player.queue.current
        if let tracked, tracked.item != current?.id {
            leave(tracked.song, at: tracked.position, duration: tracked.duration)
            self.tracked = nil
            saveQueue()
        }
        guard let current else { return }
        // While a track loads the position may read 0, and Stop resets it to 0: keep what was known.
        if let tracked, tracked.item == current.id, player.position == 0,
           player.status == .buffering || player.status == .stopped
        {
            if player.status == .stopped, lastStatus != .stopped {
                saveBookmark(tracked.song, at: tracked.position)
            }
            return
        }
        tracked = Tracked(item: current.id, song: current.song, position: player.position, duration: player.duration)
    }

    // MARK: Bookmarks

    /// The track is no longer current: keep its spot, or drop the bookmark if it played through.
    private func leave(_ song: Song, at position: TimeInterval, duration: TimeInterval) {
        guard settings.savesBookmarks, ResumePolicy.keepsSpot(song) else { return }
        let length = duration > 0 ? duration : TimeInterval(song.duration ?? 0)
        if ResumePolicy.isFinished(position: position, duration: length) {
            send(.deleteBookmark(id: song.id))
        } else {
            saveBookmark(song, at: position)
        }
    }

    private func saveBookmark(_ song: Song, at position: TimeInterval) {
        guard settings.savesBookmarks, ResumePolicy.keepsSpot(song), position >= 1 else { return }
        lastBookmarkSave = now()
        send(.createBookmark(id: song.id, position: Int64(position * 1000)))
    }

    // MARK: Play queue

    private func saveQueue() {
        guard settings.syncsPlayQueue else { return }
        lastQueueSave = now()
        let items = player.queue.items.filter { $0.song.type != "radio" }
        guard !items.isEmpty else { return }
        let current = player.queue.current.flatMap { $0.song.type == "radio" ? nil : $0.song.id }
        send(.savePlayQueue(
            songIDs: items.map(\.song.id),
            current: current,
            position: current == nil ? nil : Int64(player.position * 1000)
        ))
    }

    /// Upstream's "Load Queue": replaces the queue with the server's and plays from its spot.
    public func loadServerQueue() async throws(SubsonicError) {
        guard let saved = try await client.send(.playQueue), !saved.entries.isEmpty else { return }
        let index = saved.current.flatMap { id in saved.entries.firstIndex { $0.id == id } } ?? 0
        player.restore(SavedQueue(songs: saved.entries, currentIndex: index, positionMilliseconds: saved.position))
        player.resume()
    }

    private func send(_ request: SubsonicRequest<EmptyResponse>) {
        let client = client
        let method = request.method
        let task = Task {
            do throws(SubsonicError) {
                _ = try await client.send(request)
            } catch {
                Self.logger.notice("\(method, privacy: .public) not sent: \(error.userMessage, privacy: .public)")
            }
        }
        // Saves finish within the client's timeout; only the newest few are worth waiting for.
        pending = Array(pending.suffix(Self.pendingLimit - 1)) + [task]
    }
}

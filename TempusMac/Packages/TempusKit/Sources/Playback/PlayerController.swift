import Foundation
import Observation
import os
import Persistence
import SubsonicAPI

public enum PlaybackStatus: Sendable, Equatable {
    case stopped, buffering, playing, paused

    /// Playing or about to: what play/pause toggles away from.
    public var isActive: Bool {
        self == .playing || self == .buffering
    }
}

/// What other features hear about: scrobbling, history, Continue Listening.
public enum PlaybackEvent: Sendable, Equatable {
    /// A music track started; upstream sends `scrobble?submission=false`.
    case nowPlaying(Song)
    /// A music track counts as played: it ended, or was left past the scrobble threshold.
    case played(Song, at: Date)
}

/// Where the queue and position are kept, so playback continues after a relaunch.
public protocol QueueSaving: Sendable {
    func save(_ queue: SavedQueue, server: String) async throws
    func updateProgress(currentIndex: Int, positionMilliseconds: Int64, server: String) async throws
}

extension QueueStore: QueueSaving {}

/// The clock, sleeps and network state the controller depends on, replaceable in tests.
public struct PlayerEnvironment: Sendable {
    public let now: @Sendable () -> Date
    public let sleep: @Sendable (Duration) async throws -> Void
    /// True on a personal hotspot or in Low Data Mode (see `StreamSettings`).
    public let isOnConstrainedNetwork: @MainActor @Sendable () -> Bool

    public init(
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        isOnConstrainedNetwork: @escaping @MainActor @Sendable () -> Bool
    ) {
        self.now = now
        self.sleep = sleep
        self.isOnConstrainedNetwork = isOnConstrainedNetwork
    }

    public static let live = Self(
        now: { Date() },
        sleep: { try await Task.sleep(for: $0) },
        isOnConstrainedNetwork: { false }
    )
}

/// The player: the queue, what the engine is doing with it, and every control the UI, menus,
/// media keys and Now Playing offer. Ported from upstream `MediaManager` and `BaseMediaService`.
@MainActor
@Observable
public final class PlayerController {
    /// Previous restarts the track after this many seconds (Media3's default).
    public static let restartThreshold: TimeInterval = 3
    /// Upstream saves the position every 15 seconds while playing.
    static let progressSaveInterval: TimeInterval = 15
    static let tickInterval = Duration.milliseconds(500)
    static let volumeRestoreDelay = Duration.milliseconds(300)
    /// Plays kept for a consumer that hasn't caught up; older ones are dropped.
    static let eventBufferSize = 100
    static let logger = Logger(subsystem: "io.github.unrefundable.TempusMac", category: "Player")

    public internal(set) var queue = PlaybackQueue()
    public internal(set) var status = PlaybackStatus.stopped
    /// Seconds into the current track.
    public internal(set) var position: TimeInterval = 0
    /// The current track's length in seconds, or 0 while unknown.
    public internal(set) var duration: TimeInterval = 0
    public internal(set) var settings: PlaybackSettings
    /// Why playback stopped, when it stopped by itself. Safe to show.
    public internal(set) var errorMessage: String?
    /// A single consumer's stream of plays, for scrobbling and history.
    public let events: AsyncStream<PlaybackEvent>

    @ObservationIgnored let engine: any PlayerEngine
    @ObservationIgnored let source: any StreamSource
    @ObservationIgnored let queueSaver: (any QueueSaving)?
    @ObservationIgnored let serverID: String
    @ObservationIgnored let settingsStore: PlaybackSettingsStore
    @ObservationIgnored let environment: PlayerEnvironment
    @ObservationIgnored let eventSink: AsyncStream<PlaybackEvent>.Continuation
    /// True when the current entry is in the engine; false after a restore, a paused skip or a failure.
    @ObservationIgnored var isLoaded = false
    @ObservationIgnored var upcomingID: QueueItem.ID?
    /// Whether the loaded entry has become audible yet; seeks before then wait for it.
    @ObservationIgnored var hasCurrentStarted = false
    /// The entry whose play was already counted, so it is never counted twice.
    @ObservationIgnored var countedID: QueueItem.ID?
    /// An upcoming entry that failed to download ahead; it is not queued again until its turn.
    @ObservationIgnored var unplayableID: QueueItem.ID?
    @ObservationIgnored var pendingSeek: TimeInterval?
    @ObservationIgnored var lastProgressSave = Date.distantPast
    @ObservationIgnored var ticker: Task<Void, Never>?
    @ObservationIgnored var fade: Task<Void, Never>?
    /// The volume to unmute to.
    @ObservationIgnored var volumeBeforeMute: Double?
    @ObservationIgnored var persistence: Task<Void, Never>?
    @ObservationIgnored var nowPlaying: (any NowPlayingPublishing)?
    /// Gives up on an entry that hasn't started by then: AudioStreaming retries a dead stream (a
    /// station that's down, a server gone mid-request) forever without reporting it.
    @ObservationIgnored var startTimeout = Duration.seconds(20)
    @ObservationIgnored var startWatchdog: Task<Void, Never>?

    public init(
        engine: any PlayerEngine,
        source: any StreamSource,
        queueSaver: (any QueueSaving)?,
        serverID: String,
        settingsStore: PlaybackSettingsStore = PlaybackSettingsStore(),
        environment: PlayerEnvironment = .live
    ) {
        var settings = settingsStore.load()
        settings.sleepTimer = settings.sleepTimer.restored(now: environment.now())
        self.settings = settings
        self.engine = engine
        self.source = source
        self.queueSaver = queueSaver
        self.serverID = serverID
        self.settingsStore = settingsStore
        self.environment = environment
        (events, eventSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(Self.eventBufferSize))
        queue = PlaybackQueue(repeatMode: settings.repeatMode)
        engine.onEvent = { [weak self] event in self?.handle(event) }
        engine.apply(speed: settings.speed)
        engine.apply(equalizer: settings.equalizer)
        engine.volume = Float(settings.volume)
    }

    deinit {
        eventSink.finish() // so a consumer's loop ends with the player
    }

    /// Where the system's Now Playing info and media keys get their state.
    public func setNowPlaying(_ publisher: (any NowPlayingPublishing)?) {
        nowPlaying = publisher
        publishNowPlaying()
    }

    // MARK: Starting playback

    public func play(_ songs: [Song], startingAt index: Int = 0) {
        countSkippedTrack()
        queue = PlaybackQueue(songs: songs, startingAt: index, repeatMode: settings.repeatMode)
        load(autoplay: true)
    }

    /// Upstream's shuffle buttons shuffle the list itself and play it from the top.
    public func playShuffled(_ songs: [Song]) {
        play(songs.shuffled())
    }

    /// Puts back a saved queue, paused at the saved spot, as upstream does at launch.
    public func restore(_ saved: SavedQueue) {
        queue = PlaybackQueue(songs: saved.songs, startingAt: saved.currentIndex ?? 0, repeatMode: settings.repeatMode)
        load(autoplay: false, at: TimeInterval(saved.positionMilliseconds ?? 0) / 1000, saving: false)
    }

    // MARK: Transport

    public func togglePlayPause() {
        if status.isActive {
            pause()
        } else {
            resume()
        }
    }

    public func pause() {
        guard status.isActive else { return }
        cancelFade()
        if isLoaded {
            engine.pause()
        }
        status = .paused
        stopTicker()
        saveProgress()
        publishNowPlaying()
    }

    public func resume() {
        guard queue.current != nil, !status.isActive else { return }
        guard isLoaded, status == .paused else {
            load(autoplay: true, at: status == .stopped ? 0 : position)
            return
        }
        engine.resume()
        status = .playing
        startTicker()
        publishNowPlaying()
    }

    public func stop() {
        engine.stop()
        isLoaded = false
        status = .stopped
        position = 0
        stopTicker()
        cancelFade()
        saveProgress()
        publishNowPlaying()
    }

    public func next() {
        guard let item = queue.nextItem(afterTrackEnded: false) else { return }
        go(to: item)
    }

    /// Restarts the track, or goes to the previous one within its first three seconds.
    public func previous() {
        guard position <= Self.restartThreshold, let item = queue.previousItem() else {
            seek(to: 0)
            return
        }
        go(to: item)
    }

    /// Plays a queue entry chosen in the queue list.
    public func jump(to id: QueueItem.ID) {
        guard let item = queue.items.first(where: { $0.id == id }) else { return }
        go(to: item, autoplay: true)
    }

    public func seek(to time: TimeInterval) {
        let target = max(0, duration > 0 ? min(time, duration) : time)
        position = target
        if isLoaded, hasCurrentStarted {
            engine.seek(to: target)
        } else if isLoaded {
            pendingSeek = target // still buffering: seek once it starts
        }
        publishNowPlaying()
    }

    private func go(to item: QueueItem, autoplay: Bool? = nil) {
        countSkippedTrack()
        let shouldPlay = autoplay ?? status.isActive
        queue = queue.selecting(item.id)
        load(autoplay: shouldPlay)
    }

    // MARK: Queue

    public func playNext(_ songs: [Song]) {
        edit { $0.insertingNext(songs) }
    }

    public func addToQueue(_ songs: [Song]) {
        edit { $0.appending(songs) }
    }

    /// Empties the queue, stopping playback.
    public func clear() {
        countSkippedTrack()
        engine.stop()
        isLoaded = false
        stopTicker()
        cancelFade()
        queue = PlaybackQueue(repeatMode: settings.repeatMode)
        status = .stopped
        position = 0
        duration = 0
        saveQueue()
        publishNowPlaying()
    }

    public func remove(_ id: QueueItem.ID) {
        edit { $0.removing(id) }
    }

    public func move(_ id: QueueItem.ID, to destination: Int) {
        edit { $0.moving(id, to: destination) }
    }

    public func toggleShuffle() {
        var generator = SystemRandomNumberGenerator()
        edit { $0.isShuffled ? $0.unshuffled() : $0.shuffled(using: &generator) }
    }

    public func shuffleUpcoming() {
        var generator = SystemRandomNumberGenerator()
        edit { $0.shufflingUpcoming(using: &generator) }
    }

    public func cycleRepeatMode() {
        setRepeatMode(settings.repeatMode.next)
    }

    public func setRepeatMode(_ mode: RepeatMode) {
        updateSettings { $0.repeatMode = mode }
        queue = queue.repeating(mode)
        refreshUpcoming()
    }

    private func edit(_ change: (PlaybackQueue) -> PlaybackQueue) {
        let wasIdle = queue.current == nil
        queue = change(queue)
        if wasIdle, queue.current != nil {
            load(autoplay: true)
            return
        }
        refreshUpcoming()
        saveQueue()
    }

    // MARK: Settings

    public func setSpeed(_ speed: PlaybackSpeed) {
        updateSettings { $0.speed = speed }
        engine.apply(speed: speed)
        publishNowPlaying()
    }

    public func setReplayGain(_ replayGain: ReplayGainSettings) {
        updateSettings { $0.replayGain = replayGain }
        applyGain()
    }

    public func setEqualizer(_ equalizer: EqualizerSettings) {
        updateSettings { $0.equalizer = equalizer }
        engine.apply(equalizer: equalizer)
    }

    /// New quality applies from the next track; the playing one isn't interrupted (as upstream).
    public func setStreamSettings(_ stream: StreamSettings) {
        updateSettings { $0.stream = stream }
        refreshUpcoming(force: true)
    }

    /// Sets the player's volume, 0–1. A sleep-timer fade in progress carries on from the new level.
    public func setVolume(_ volume: Double) {
        let clamped = PlaybackSettings.clampedVolume(volume)
        guard clamped != settings.volume else { return }
        if clamped > 0 {
            volumeBeforeMute = nil
        }
        updateSettings { $0.volume = clamped }
        if fade == nil {
            engine.volume = Float(clamped)
        }
    }

    /// Mutes, or puts back the volume from before muting (full volume if it was muted at launch).
    public func toggleMute() {
        if settings.volume > 0 {
            let previous = settings.volume
            setVolume(0)
            volumeBeforeMute = previous
        } else {
            setVolume(volumeBeforeMute ?? 1)
        }
    }

    public func setSleepTimer(_ timer: SleepTimer) {
        cancelFade()
        updateSettings { $0.sleepTimer = timer }
    }

    func updateSettings(_ change: (inout PlaybackSettings) -> Void) {
        change(&settings)
        settingsStore.save(settings)
    }
}

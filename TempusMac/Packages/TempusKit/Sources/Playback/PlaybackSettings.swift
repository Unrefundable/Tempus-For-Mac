import Foundation
import os

/// Everything the player remembers between launches. None of it is secret, so it lives in
/// `UserDefaults` (upstream's SharedPreferences).
public struct PlaybackSettings: Codable, Sendable, Equatable {
    public var repeatMode: RepeatMode
    public var speed: PlaybackSpeed
    public var replayGain: ReplayGainSettings
    public var equalizer: EqualizerSettings
    public var stream: StreamSettings
    public var sleepTimer: SleepTimer
    /// The player's own volume from 0 to 1, on top of the system's. See `clampedVolume(_:)`.
    public var volume: Double

    public init(
        repeatMode: RepeatMode = .off,
        speed: PlaybackSpeed = PlaybackSpeed(),
        replayGain: ReplayGainSettings = ReplayGainSettings(),
        equalizer: EqualizerSettings = EqualizerSettings(),
        stream: StreamSettings = StreamSettings(),
        sleepTimer: SleepTimer = .off,
        volume: Double = 1
    ) {
        self.repeatMode = repeatMode
        self.speed = speed
        self.replayGain = replayGain
        self.equalizer = equalizer
        self.stream = stream
        self.sleepTimer = sleepTimer
        self.volume = Self.clampedVolume(volume)
    }

    /// `volume` within 0–1; anything unreadable (NaN, say) is full volume.
    public static func clampedVolume(_ volume: Double) -> Double {
        volume.isFinite ? min(max(volume, 0), 1) : 1
    }

    /// Each setting falls back to its default on its own, so one unreadable or newly added
    /// setting never resets the others.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        let defaults = Self()
        self.init(
            repeatMode: value(.repeatMode, defaults.repeatMode),
            speed: value(.speed, defaults.speed),
            replayGain: value(.replayGain, defaults.replayGain),
            equalizer: value(.equalizer, defaults.equalizer),
            stream: value(.stream, defaults.stream),
            sleepTimer: value(.sleepTimer, defaults.sleepTimer),
            volume: value(.volume, defaults.volume)
        )
    }
}

/// Loads and saves `PlaybackSettings` as one JSON value.
@MainActor
public struct PlaybackSettingsStore {
    static let key = "playback.settings"
    private static let logger = Logger(subsystem: "io.github.unrefundable.TempusMac", category: "PlaybackSettings")

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> PlaybackSettings {
        guard let data = defaults.data(forKey: Self.key) else { return PlaybackSettings() }
        do {
            return try JSONDecoder().decode(PlaybackSettings.self, from: data)
        } catch {
            Self.logger.error("Playback settings are unreadable, using defaults: \(error)")
            return PlaybackSettings()
        }
    }

    public func save(_ settings: PlaybackSettings) {
        do {
            try defaults.set(JSONEncoder().encode(settings), forKey: Self.key)
        } catch {
            Self.logger.error("Couldn't save playback settings: \(error)")
        }
    }
}

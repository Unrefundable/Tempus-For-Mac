import Foundation
import SubsonicAPI

public enum PitchMode: Codable, Sendable, Hashable {
    /// Pitch stays put while the speed changes.
    case fixed
    /// Pitch rises and falls with the speed, like a tape.
    case followsRate
    /// A pitch factor set by hand (0.25–2), independent of the speed.
    case manual(Double)
}

/// Playback speed and pitch, as upstream's speed dialog (`playback_speed*` preferences).
public struct PlaybackSpeed: Codable, Sendable, Equatable {
    public static let range: ClosedRange<Double> = 0.25 ... 2

    public let rate: Double
    public let pitch: PitchMode

    public init(rate: Double = 1, pitch: PitchMode = .fixed) {
        self.rate = rate.isFinite ? rate.clamped(to: Self.range) : 1
        if case let .manual(factor) = pitch {
            self.pitch = .manual(factor.isFinite ? factor.clamped(to: Self.range) : 1)
        } else {
            self.pitch = pitch
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            rate: container.decode(Double.self, forKey: .rate),
            pitch: container.decode(PitchMode.self, forKey: .pitch)
        )
    }

    /// The pitch shift for the time-pitch unit, in cents.
    public var pitchCents: Double {
        switch pitch {
        case .fixed: 0
        case .followsRate: 1200 * log2(rate)
        case let .manual(factor): 1200 * log2(factor)
        }
    }
}

/// Upstream's sleep timer (`SleepTimerManager`): a countdown or the end of the current track,
/// then the volume fades out over 10 seconds and playback pauses.
public enum SleepTimer: Codable, Sendable, Equatable {
    case off
    case until(Date)
    case endOfTrack

    public static let presetMinutes = [5, 10, 15, 20, 30, 45, 60]
    public static let fadeSteps = 40
    public static let fadeStepInterval = Duration.milliseconds(250)
    /// End of track starts fading when this much of the track is left.
    static let endOfTrackWindow: ClosedRange<TimeInterval> = 0.001 ... 10

    public static func starting(minutes: Int, now: Date) -> Self? {
        minutes > 0 ? .until(now + TimeInterval(minutes * 60)) : nil
    }

    /// Seconds left on a countdown; nil for no timer or end of track.
    public func remaining(now: Date) -> TimeInterval? {
        guard case let .until(end) = self else { return nil }
        return max(0, end.timeIntervalSince(now))
    }

    public func shouldStartFade(now: Date, timeLeftInTrack: TimeInterval?) -> Bool {
        switch self {
        case .off: false
        case let .until(end): now >= end
        case .endOfTrack: timeLeftInTrack.map(Self.endOfTrackWindow.contains) ?? false
        }
    }

    /// The timer after a relaunch: end of track is kept, a countdown only if it hasn't run out.
    public func restored(now: Date) -> Self {
        if case let .until(end) = self, end <= now {
            return .off
        }
        return self
    }

    /// The volume after `step` of the fade's steps.
    public static func fadeVolume(afterStep step: Int) -> Float {
        Float(1 - Double(step.clamped(to: 0 ... fadeSteps)) / Double(fadeSteps))
    }
}

/// When a play counts, as upstream `MediaManager.meetsScrobbleThreshold`.
public enum ScrobblePolicy {
    static let minimumDuration: TimeInterval = 30
    static let maximumListen: TimeInterval = 240

    /// Only music is scrobbled and kept in history, not podcasts or audiobooks.
    public static func counts(_ song: Song) -> Bool {
        song.type.map { $0 == "music" } ?? true
    }

    /// For a track left early: it counts after half its length or four minutes, whichever comes
    /// first, unless it is 30 seconds or shorter. A track that plays to the end always counts.
    public static func meetsThreshold(duration: TimeInterval, position: TimeInterval) -> Bool {
        duration > minimumDuration && position >= min(duration / 2, maximumListen)
    }
}

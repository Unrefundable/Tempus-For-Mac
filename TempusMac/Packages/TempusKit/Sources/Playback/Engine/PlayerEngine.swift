import Foundation
import SubsonicAPI

/// A queue entry's stream, as the engine plays it.
public struct EngineItem: Sendable, Hashable {
    public let id: QueueItem.ID
    /// Carries credentials: never log it.
    public let url: URL
    public let headers: [String: String]

    public init(id: QueueItem.ID, url: URL, headers: [String: String]) {
        self.id = id
        self.url = url
        self.headers = headers
    }
}

public enum EngineState: Sendable, Equatable {
    case idle, buffering, playing, paused, stopped
}

public enum EngineFinish: Sendable, Equatable {
    /// The track played to its end.
    case ended
    case failed
    /// Replaced or stopped by the app.
    case stopped
}

public enum EngineEvent: Sendable, Equatable {
    /// An entry became audible: the first one, or the next one in a gapless transition.
    case started(QueueItem.ID)
    case finished(QueueItem.ID, EngineFinish)
    case stateChanged(EngineState)
    /// Something went wrong that stops playback: reading `entry` failed (nil when it isn't known).
    /// The entry may be the upcoming one, which the engine downloads while the current one plays.
    /// The message is safe to show.
    case failed(entry: QueueItem.ID?, message: String)
}

/// The audio engine the player controller drives. It plays one entry and keeps the next one ready
/// so the two join without a gap.
@MainActor
public protocol PlayerEngine: AnyObject {
    var onEvent: (@MainActor (EngineEvent) -> Void)? { get set }
    /// Seconds into the playing entry.
    var progress: TimeInterval { get }
    /// The playing entry's length in seconds, or 0 while unknown.
    var duration: TimeInterval { get }
    /// 0–1: the player's volume setting, scaled down during the sleep timer's fade.
    var volume: Float { get set }

    /// Stops whatever is playing and plays `item`. Any upcoming entry is dropped.
    func play(_ item: EngineItem)
    /// Replaces the entry that plays after the current one; nil clears it.
    func setUpcoming(_ item: EngineItem?)
    func pause()
    func resume()
    func stop()
    func seek(to time: TimeInterval)
    func apply(speed: PlaybackSpeed)
    func apply(equalizer: EqualizerSettings)
    /// ReplayGain and preamp for the playing entry, in dB.
    func setGain(decibels: Double)
}

/// Turns a queue entry into the stream request the engine plays.
public protocol StreamSource: Sendable {
    func streamItem(for item: QueueItem, quality: StreamQuality) throws(SubsonicError) -> EngineItem
}

/// Streams from a Subsonic server, with its custom headers for that server only.
public struct SubsonicStreamSource: StreamSource {
    private let client: SubsonicClient

    public init(client: SubsonicClient) {
        self.client = client
    }

    public func streamItem(for item: QueueItem, quality: StreamQuality) throws(SubsonicError) -> EngineItem {
        let url = try client.streamURL(id: item.song.id, quality: quality)
        return EngineItem(id: item.id, url: url, headers: client.mediaRequestPolicy.headers(for: url))
    }
}

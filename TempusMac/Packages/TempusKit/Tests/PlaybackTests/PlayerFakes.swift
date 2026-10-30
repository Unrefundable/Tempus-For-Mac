import Foundation
import Persistence
@testable import Playback
import SubsonicAPI
import Synchronization

/// Records what the controller asks of the engine; tests drive its events by hand.
@MainActor
final class FakeEngine: PlayerEngine {
    var onEvent: (@MainActor (EngineEvent) -> Void)?
    var progress: TimeInterval = 0
    var duration: TimeInterval = 0
    var volume: Float = 1
    private(set) var played: [EngineItem] = []
    private(set) var upcoming: EngineItem?
    private(set) var calls: [String] = []
    private(set) var gainDB = 0.0
    private(set) var speed = PlaybackSpeed()
    private(set) var equalizer = EqualizerSettings()

    var playedSongIDs: [String] {
        played.map(\.url.lastPathComponent)
    }

    func play(_ item: EngineItem) {
        played.append(item)
        upcoming = nil
        calls.append("play")
    }

    func setUpcoming(_ item: EngineItem?) {
        upcoming = item
    }

    func pause() {
        calls.append("pause")
    }

    func resume() {
        calls.append("resume")
    }

    func stop() {
        upcoming = nil
        calls.append("stop")
    }

    func seek(to time: TimeInterval) {
        calls.append("seek \(time)")
    }

    func apply(speed: PlaybackSpeed) {
        self.speed = speed
    }

    func apply(equalizer: EqualizerSettings) {
        self.equalizer = equalizer
    }

    func setGain(decibels: Double) {
        gainDB = decibels
    }

    func send(_ event: EngineEvent) {
        onEvent?(event)
    }
}

/// Streams `https://music.example.com/<quality>/<song id>`, so tests can see what was asked for.
struct FakeSource: StreamSource {
    func streamItem(for item: QueueItem, quality: StreamQuality) throws(SubsonicError) -> EngineItem {
        let label = switch quality {
        case .serverDefault: "default"
        case .original: "original"
        case let .transcoded(format, bitrate): "\(format)-\(bitrate)"
        }
        guard let url = URL(string: "https://music.example.com/\(label)/\(item.song.id)") else {
            throw .invalidServerAddress
        }
        return EngineItem(id: item.id, url: url, headers: [:])
    }
}

final class FakeQueueSaver: QueueSaving {
    struct Progress: Equatable {
        let index: Int
        let milliseconds: Int64
    }

    private let state = Mutex<(queues: [SavedQueue], progress: [Progress])>(([], []))

    var queues: [SavedQueue] {
        state.withLock { $0.queues }
    }

    var progress: [Progress] {
        state.withLock { $0.progress }
    }

    func save(_ queue: SavedQueue, server _: String) async throws {
        state.withLock { $0.queues.append(queue) }
    }

    func updateProgress(currentIndex: Int, positionMilliseconds: Int64, server _: String) async throws {
        state.withLock { $0.progress.append(Progress(index: currentIndex, milliseconds: positionMilliseconds)) }
    }
}

extension PlayerEnvironment {
    /// A fixed clock and sleeps that return at once, so fades finish immediately.
    static func test(now: Date) -> Self {
        Self(now: { now }, sleep: { _ in }, isOnConstrainedNetwork: { false })
    }
}

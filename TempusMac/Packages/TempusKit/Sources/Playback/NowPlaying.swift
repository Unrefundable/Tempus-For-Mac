import Foundation
import MediaPlayer
import SubsonicAPI

/// What the system shows for the current track.
public struct NowPlayingSnapshot: Sendable, Equatable {
    public let song: Song
    public let position: TimeInterval
    public let duration: TimeInterval
    /// 0 when not playing, so the system stops advancing the elapsed time.
    public let rate: Double
    public let status: PlaybackStatus
    public let queueIndex: Int
    public let queueCount: Int
}

@MainActor
public protocol NowPlayingPublishing: AnyObject {
    /// Nil when nothing is queued.
    func publish(_ snapshot: NowPlayingSnapshot?)
}

/// The system's Now Playing (Control Center and the menu bar) and the media keys, AirPods and
/// Touch Bar controls that come with it. Upstream's MediaSession and notification controls.
@MainActor
public final class SystemNowPlaying: NowPlayingPublishing {
    private let center = MPNowPlayingInfoCenter.default()
    private weak var player: PlayerController?

    public init(player: PlayerController) {
        self.player = player
        registerCommands()
        player.setNowPlaying(self)
    }

    public func publish(_ snapshot: NowPlayingSnapshot?) {
        guard let snapshot else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        center.nowPlayingInfo = Self.info(for: snapshot)
        center.playbackState = switch snapshot.status {
        case .playing, .buffering: .playing
        case .paused: .paused
        case .stopped: .stopped
        }
    }

    static func info(for snapshot: NowPlayingSnapshot) -> [String: Any] {
        let song = snapshot.song
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title ?? "",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.position,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: snapshot.queueIndex,
            MPNowPlayingInfoPropertyPlaybackQueueCount: snapshot.queueCount,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        info[MPMediaItemPropertyArtist] = song.artist
        info[MPMediaItemPropertyAlbumTitle] = song.album
        info[MPMediaItemPropertyAlbumArtist] = song.albumArtist
        info[MPMediaItemPropertyAlbumTrackNumber] = song.track
        if snapshot.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = snapshot.duration
        }
        return info
    }

    // MARK: Remote commands

    private func registerCommands() {
        let commands = MPRemoteCommandCenter.shared()
        on(commands.playCommand) { $0.resume() }
        on(commands.pauseCommand) { $0.pause() }
        on(commands.togglePlayPauseCommand) { $0.togglePlayPause() }
        on(commands.stopCommand) { $0.stop() }
        on(commands.nextTrackCommand) { $0.next() }
        on(commands.previousTrackCommand) { $0.previous() }

        // Handlers are `@Sendable`, not main-actor closures: the system may call them off the main
        // thread, and a main-actor closure would trap there. Values come out of the event first.
        enable(commands.changePlaybackPositionCommand)
        commands.changePlaybackPositionCommand.addTarget { @Sendable [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else {
                return .commandFailed
            }
            return self?.perform { $0.seek(to: position) } ?? .noActionableNowPlayingItem
        }
        enable(commands.changeRepeatModeCommand)
        commands.changeRepeatModeCommand.addTarget { @Sendable [weak self] event in
            guard let type = (event as? MPChangeRepeatModeCommandEvent)?.repeatType else { return .commandFailed }
            let mode: RepeatMode = switch type {
            case .one: .one
            case .all: .all
            default: .off
            }
            return self?.perform { $0.setRepeatMode(mode) } ?? .noActionableNowPlayingItem
        }
        enable(commands.changeShuffleModeCommand)
        commands.changeShuffleModeCommand.addTarget { @Sendable [weak self] event in
            guard let type = (event as? MPChangeShuffleModeCommandEvent)?.shuffleType else { return .commandFailed }
            let shuffled = type != .off
            return self?.perform { player in
                if player.queue.isShuffled != shuffled {
                    player.toggleShuffle()
                }
            } ?? .noActionableNowPlayingItem
        }
    }

    private func enable(_ command: MPRemoteCommand) {
        command.isEnabled = true
    }

    private func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor @Sendable (PlayerController) -> Void) {
        enable(command)
        command.addTarget { @Sendable [weak self] _ in
            self?.perform(action) ?? .noActionableNowPlayingItem
        }
    }

    /// Commands may arrive off the main thread; the player only runs on it.
    private nonisolated func perform(
        _ action: @escaping @MainActor @Sendable (PlayerController) -> Void
    ) -> MPRemoteCommandHandlerStatus {
        Task { @MainActor [weak self] in
            guard let player = self?.player else { return }
            action(player)
        }
        return .success
    }
}

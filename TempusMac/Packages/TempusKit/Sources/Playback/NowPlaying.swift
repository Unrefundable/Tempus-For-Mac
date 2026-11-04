import AppKit
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

    public init(
        song: Song,
        position: TimeInterval,
        duration: TimeInterval,
        rate: Double,
        status: PlaybackStatus,
        queueIndex: Int,
        queueCount: Int
    ) {
        self.song = song
        self.position = position
        self.duration = duration
        self.rate = rate
        self.status = status
        self.queueIndex = queueIndex
        self.queueCount = queueCount
    }
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
    private var artwork: (songID: String, artwork: MPMediaItemArtwork)?
    private var lastSongID: String?
    /// Whether this player has told the system it's playing, which wins it the media keys.
    private var mediaKeysClaimed = false
    private var reportedState = MPNowPlayingPlaybackState.stopped
    private var claimRelease: Task<Void, Never>?

    /// Also gets every snapshot published here, such as Discord's status. Its owner keeps it alive.
    public weak var mirror: (any NowPlayingPublishing)?

    /// Registers the remote commands once. Create one for the life of the app and `attach` each
    /// player to it, since the command center keeps every handler ever added.
    public init() {
        registerCommands()
    }

    public convenience init(player: PlayerController) {
        self.init()
        attach(to: player)
    }

    /// Routes the media keys to `player` and publishes its state, replacing any earlier player.
    public func attach(to player: PlayerController) {
        self.player?.setNowPlaying(nil)
        artwork = nil // song ids repeat across servers
        endClaim()
        mediaKeysClaimed = false
        self.player = player
        player.setNowPlaying(self)
    }

    /// Stops routing commands and clears the system's Now Playing.
    public func detach() {
        player?.setNowPlaying(nil)
        player = nil
        artwork = nil
        endClaim()
        publish(nil)
    }

    /// The cover for `songID`, shown while that song is current. Artwork loads after the track
    /// starts, so it is kept and merged into every later publish.
    public func setArtwork(_ image: NSImage?, forSongID songID: String) {
        guard let image else {
            if artwork?.songID == songID {
                artwork = nil
            }
            return
        }
        let box = ImageBox(image: image)
        artwork = (songID, MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in box.image })
        if lastSongID == songID, var info = center.nowPlayingInfo {
            info[MPMediaItemPropertyArtwork] = artwork?.artwork
            center.nowPlayingInfo = info
        }
    }

    public func publish(_ snapshot: NowPlayingSnapshot?) {
        mirror?.publish(snapshot)
        guard let snapshot else {
            lastSongID = nil
            center.nowPlayingInfo = nil
            report(.stopped, claiming: false)
            return
        }
        lastSongID = snapshot.song.id
        var info = Self.info(for: snapshot)
        if let artwork, artwork.songID == snapshot.song.id {
            info[MPMediaItemPropertyArtwork] = artwork.artwork
        }
        center.nowPlayingInfo = info
        report(Self.playbackState(for: snapshot.status), claiming: Self.claimsMediaKeys(
            reporting: snapshot.status,
            hasClaimed: mediaKeysClaimed
        ))
        mediaKeysClaimed = Self.hasClaimedMediaKeys(after: snapshot.status, hadClaimed: mediaKeysClaimed)
    }

    static func playbackState(for status: PlaybackStatus) -> MPNowPlayingPlaybackState {
        switch status {
        case .playing, .buffering: .playing
        case .paused: .paused
        case .stopped: .stopped
        }
    }

    /// macOS sends the media keys to the app that last reported playing. A queue restored paused
    /// at launch never has, so the keys went to another app (or opened Music) until Tempus was
    /// clicked. Its first report says playing for a moment to claim them.
    static func claimsMediaKeys(reporting status: PlaybackStatus, hasClaimed: Bool) -> Bool {
        !hasClaimed && status == .paused
    }

    /// A stopped report (a queue still loading) leaves the claim for the paused one that follows.
    static func hasClaimedMediaKeys(after status: PlaybackStatus, hadClaimed: Bool) -> Bool {
        hadClaimed || status != .stopped
    }

    private func report(_ state: MPNowPlayingPlaybackState, claiming: Bool) {
        reportedState = state
        // While a claim is held, later reports wait for it to end, so the system sees playing.
        guard claimRelease == nil else { return }
        guard claiming else {
            center.playbackState = state
            return
        }
        center.playbackState = .playing
        claimRelease = Task { [weak self] in
            try? await Task.sleep(for: Self.claimHold)
            guard !Task.isCancelled else { return }
            self?.endClaim()
        }
    }

    /// Ends any claim early or on time, and shows the state reported since.
    private func endClaim() {
        guard let claim = claimRelease else { return }
        claim.cancel()
        claimRelease = nil
        center.playbackState = reportedState
    }

    private static let claimHold = Duration.milliseconds(300)

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

/// `MPMediaItemArtwork` may ask for the image on any thread. The image is never changed after it
/// is handed over, so sharing it is safe.
private struct ImageBox: @unchecked Sendable {
    let image: NSImage
}

import AudioStreaming
import AVFoundation
import Foundation
import os
import SubsonicAPI
import Synchronization

/// `PlayerEngine` on AudioStreaming (patched for gapless MP3/AAC, see ADR 0001), with one
/// `AVAudioUnitEQ` for the equalizer, ReplayGain and the profile preamp (its `globalGain`).
@MainActor
public final class StreamingEngine: PlayerEngine {
    public var onEvent: (@MainActor (EngineEvent) -> Void)?

    private static let logger = Logger(subsystem: "io.github.unrefundable.TempusMac", category: "StreamingEngine")
    /// `AVAudioUnitEQ.globalGain`'s limits.
    private static let globalGainRange: ClosedRange<Double> = -96 ... 24
    private static let fallbackSampleRate = 44100.0

    private let player: AudioPlayer
    /// Internal so tests can check the bands.
    let equalizerNode = AVAudioUnitEQ(numberOfBands: EqualizerSettings.bandCount)
    private let policy: PolicyBox
    private let delegateProxy = DelegateProxy()
    /// AudioStreaming entry ids (unique URLs) to queue entries.
    private var entries: [String: QueueItem.ID] = [:]
    private var upcomingKey: String?
    /// AudioStreaming clears its queue asynchronously after `play`, so an entry queued before the
    /// new one starts would be lost (found in the ADR 0001 spike). It waits here until then.
    private var hasStarted = false
    private var heldUpcoming: EngineItem?
    /// AudioStreaming ignores `pause` until the entry is running, so a pause that early is kept here.
    private var isPausePending = false
    /// The playing entry, and whether it has finished downloading. Once it has, AudioStreaming reads
    /// the upcoming entry, so a read failure then belongs to that one.
    private var playingKey: String?
    private var isPlayingBuffered = false
    private var equalizer = EqualizerSettings()
    private var gainDB = 0.0

    /// - Parameter policy: the server's rules for headers on redirects and client certificates.
    public init(policy: MediaRequestPolicy? = nil) {
        let box = PolicyBox(policy)
        self.policy = box
        player = AudioPlayer(
            configuration: AudioPlayerConfiguration(flushQueueOnSeek: false, enableLogs: false),
            clientCertificateProvider: { challenge in box.current?.credential(for: challenge.protectionSpace) },
            redirectHandler: { _, request in
                box.current?.request(followingRedirectTo: request)
                    ?? MediaRequestPolicy.requestWithoutPolicy(followingRedirectTo: request)
            }
        )
        player.attach(node: equalizerNode)
        delegateProxy.engine = self
        player.delegate = delegateProxy
        apply(equalizer: equalizer)
    }

    /// Switches to another server's rules. Playback stops first, so no request still running for the
    /// old server is judged by the new server's rules.
    public func setPolicy(_ policy: MediaRequestPolicy?) {
        stop()
        self.policy.current = policy
    }

    public var progress: TimeInterval {
        player.progress
    }

    public var duration: TimeInterval {
        player.duration
    }

    public var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    public func play(_ item: EngineItem) {
        let key = Self.entryURL(for: item)
        resetEntries()
        entries = [key.absoluteString: item.id]
        playingKey = key.absoluteString
        player.play(url: key, headers: item.headers)
    }

    private func resetEntries() {
        entries = [:]
        upcomingKey = nil
        hasStarted = false
        heldUpcoming = nil
        isPausePending = false
        playingKey = nil
        isPlayingBuffered = false
    }

    public func setUpcoming(_ item: EngineItem?) {
        guard hasStarted else {
            heldUpcoming = item
            return
        }
        if let upcomingKey, let url = URL(string: upcomingKey) {
            player.removeFromQueue(url: url)
            entries[upcomingKey] = nil
        }
        upcomingKey = nil
        guard let item else { return }
        let key = Self.entryURL(for: item)
        entries[key.absoluteString] = item.id
        upcomingKey = key.absoluteString
        player.queue(url: key, headers: item.headers)
    }

    public func pause() {
        if !hasStarted {
            isPausePending = true
        }
        player.pause()
    }

    public func resume() {
        isPausePending = false
        player.resume()
    }

    public func stop() {
        resetEntries()
        player.stop()
    }

    public func seek(to time: TimeInterval) {
        player.seek(to: time)
    }

    public func apply(speed: PlaybackSpeed) {
        player.rate = Float(speed.rate)
        player.pitch = Float(speed.pitchCents)
    }

    public func apply(equalizer: EqualizerSettings) {
        self.equalizer = equalizer
        let sampleRate = player.mainMixerNode.outputFormat(forBus: 0).sampleRate
        let bands = equalizer.bands(sampleRate: sampleRate > 0 ? sampleRate : Self.fallbackSampleRate)
        for (node, band) in zip(equalizerNode.bands, bands) {
            node.filterType = switch band.kind {
            case .parametric: .parametric
            case .lowShelf: .lowShelf
            case .highShelf: .highShelf
            }
            node.frequency = band.frequency
            node.gain = band.gainDB
            node.bandwidth = band.bandwidthOctaves
            node.bypass = band.isBypassed
        }
        updateGlobalGain()
    }

    public func setGain(decibels: Double) {
        gainDB = decibels
        updateGlobalGain()
    }

    private func updateGlobalGain() {
        equalizerNode.globalGain = Float((gainDB + equalizer.preampDB).clamped(to: Self.globalGainRange))
    }

    /// AudioStreaming names entries by URL and stops playback when asked to remove an upcoming
    /// entry whose URL matches the playing one. A fragment makes every entry unique; fragments are
    /// never sent to the server.
    private static func entryURL(for item: EngineItem) -> URL {
        let base = item.url.absoluteString.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
        return URL(string: "\(base)#entry=\(UUID().uuidString)") ?? item.url
    }

    // MARK: AudioStreaming callbacks (always on the main queue)

    fileprivate func didStart(entry key: String) {
        guard let id = entries[key] else { return }
        if key == upcomingKey {
            upcomingKey = nil
        }
        if key != playingKey {
            playingKey = key
            isPlayingBuffered = false
        }
        if !hasStarted {
            hasStarted = true
            let held = heldUpcoming
            heldUpcoming = nil
            if let held {
                setUpcoming(held)
            }
            if isPausePending {
                isPausePending = false
                player.pause()
            }
        }
        onEvent?(.started(id))
    }

    fileprivate func didFinishBuffering(entry key: String) {
        if key == playingKey {
            isPlayingBuffered = true
        }
    }

    fileprivate func didFinish(entry key: String, reason: AudioPlayerStopReason) {
        guard let id = entries.removeValue(forKey: key) else { return }
        // A gapless hand-off reports `.none`; only the last entry gets `.eof`. Entries the app
        // replaced never get here, because `play` forgets them first.
        let finish: EngineFinish = switch reason {
        case .eof, .none: .ended
        case .error: .failed
        case .userAction, .disposed: .stopped
        }
        onEvent?(.finished(id, finish))
    }

    fileprivate func didCancel(entries keys: [String]) {
        for key in keys {
            entries[key] = nil
            if key == upcomingKey {
                upcomingKey = nil
            }
        }
    }

    fileprivate func stateChanged(to state: AudioPlayerState) {
        let mapped: EngineState = switch state {
        case .ready: .idle
        case .running, .bufferring: .buffering
        case .playing: .playing
        case .paused: .paused
        case .stopped, .disposed, .error: .stopped
        }
        onEvent?(.stateChanged(mapped))
    }

    fileprivate func failed(_ error: AudioPlayerError) {
        Self.logger.error("Playback failed: \(error.localizedDescription, privacy: .public)")
        let failedKey = isPlayingBuffered ? upcomingKey ?? playingKey : playingKey
        onEvent?(.failed(entry: failedKey.flatMap { entries[$0] }, message: Self.message(for: error)))
    }

    private static func message(for error: AudioPlayerError) -> String {
        switch error {
        case .networkError, .dataNotFound: String(localized: "The server couldn't be reached.")
        case .codecError, .streamParseBytesFailure: String(localized: "This track's format can't be played.")
        case .audioSystemError, .other: String(localized: "The audio system stopped unexpectedly.")
        }
    }
}

/// The current server's media policy, read from AudioStreaming's network queue.
private final class PolicyBox: Sendable {
    private let state: Mutex<MediaRequestPolicy?>

    init(_ policy: MediaRequestPolicy?) {
        state = Mutex(policy)
    }

    var current: MediaRequestPolicy? {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

/// AudioStreaming's delegate. It calls back on the main queue (`asyncOnMain`); only plain values
/// cross into the main actor, since AudioStreaming's own types aren't `Sendable`.
@MainActor
private final class DelegateProxy: AudioPlayerDelegate {
    weak var engine: StreamingEngine?

    nonisolated func audioPlayerDidStartPlaying(player _: AudioPlayer, with entryId: AudioEntryId) {
        let key = entryId.id
        MainActor.assumeIsolated { engine?.didStart(entry: key) }
    }

    nonisolated func audioPlayerDidFinishBuffering(player _: AudioPlayer, with entryId: AudioEntryId) {
        let key = entryId.id
        MainActor.assumeIsolated { engine?.didFinishBuffering(entry: key) }
    }

    nonisolated func audioPlayerStateChanged(
        player _: AudioPlayer,
        with newState: AudioPlayerState,
        previous _: AudioPlayerState
    ) {
        MainActor.assumeIsolated { engine?.stateChanged(to: newState) }
    }

    nonisolated func audioPlayerDidFinishPlaying(
        player _: AudioPlayer,
        entryId: AudioEntryId,
        stopReason: AudioPlayerStopReason,
        progress _: Double,
        duration _: Double
    ) {
        let key = entryId.id
        MainActor.assumeIsolated { engine?.didFinish(entry: key, reason: stopReason) }
    }

    nonisolated func audioPlayerUnexpectedError(player _: AudioPlayer, error: AudioPlayerError) {
        MainActor.assumeIsolated { engine?.failed(error) }
    }

    nonisolated func audioPlayerDidCancel(player _: AudioPlayer, queuedItems: [AudioEntryId]) {
        let keys = queuedItems.map(\.id)
        MainActor.assumeIsolated { engine?.didCancel(entries: keys) }
    }

    nonisolated func audioPlayerDidReadMetadata(player _: AudioPlayer, metadata _: [String: String]) {}
}

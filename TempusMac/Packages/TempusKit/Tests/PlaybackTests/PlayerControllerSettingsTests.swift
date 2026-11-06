import Foundation
@testable import Playback
import SubsonicAPI
import Testing

/// Sound, streaming and sleep-timer settings, kept apart to keep each file short.
extension PlayerControllerTests {
    @Test("ReplayGain follows the playing track")
    func replayGain() throws {
        let settings = PlaybackSettings(replayGain: ReplayGainSettings(mode: .track))
        let player = controller(settings)
        try player.play([
            song("a", replayGain: #"{"trackGain":-7}"#),
            song("b", replayGain: #"{"trackGain":-3}"#),
        ])
        #expect(engine.gainDB == -7)

        engine.send(.started(player.queue.items[1].id))
        #expect(engine.gainDB == -3)
    }

    @Test("Tracks the player can't decode are requested transcoded")
    func transcodesUnplayable() throws {
        let player = controller()
        try player.play([song("a", suffix: "opus")])
        #expect(engine.played.first?.url.pathComponents.dropLast().last == "mp3-320")
    }

    @Test("Speed and equalizer changes reach the engine and are saved")
    func settingsApplied() {
        let player = controller()
        player.setSpeed(PlaybackSpeed(rate: 1.5))
        player.setEqualizer(EqualizerSettings(mode: .graphic, graphicGains: [3]))

        #expect(engine.speed.rate == 1.5)
        #expect(engine.equalizer.mode == .graphic)
        #expect(PlaybackSettingsStore(defaults: defaults).load().speed.rate == 1.5)
    }

    @Test("The sleep timer fades out and pauses at the end of the track")
    func sleepAtEndOfTrack() async throws {
        let player = try playing(["a", "b"])
        player.setSleepTimer(.endOfTrack)
        engine.duration = 200
        engine.progress = 195

        player.tick()
        await player.settled()

        #expect(engine.calls.contains("pause"))
        #expect(player.status == .paused)
        #expect(player.settings.sleepTimer == .off)
        #expect(engine.volume == 1)
    }

    @Test("A countdown sleep timer fades out when it runs out")
    func sleepCountdown() async throws {
        let player = try playing(["a"])
        player.setSleepTimer(.until(now))

        player.tick()
        await player.settled()

        #expect(player.status == .paused)
    }

    @Test("New stream settings apply from the next track")
    func streamSettingsChange() throws {
        let player = try playing(["a", "b"])
        player.setStreamSettings(StreamSettings(format: .mp3, maxBitrate: 128))

        #expect(engine.played.first?.url.pathComponents.dropLast().last == "original")
        #expect(engine.upcoming?.url.pathComponents.dropLast().last == "mp3-128")
    }

    @Test("ReplayGain changes apply to the playing track at once")
    func replayGainChange() throws {
        let player = controller()
        try player.play([song("a", replayGain: #"{"trackGain":-4}"#)])
        #expect(engine.gainDB == 0)

        player.setReplayGain(ReplayGainSettings(mode: .track, preampDB: 1))
        #expect(engine.gainDB == -3)
    }

    @Test("If a track ends before the end-of-track fade, playback pauses anyway")
    func sleepSafetyNet() throws {
        let player = try playing(["a", "b"])
        player.setSleepTimer(.endOfTrack)

        engine.send(.finished(player.queue.items[0].id, .ended))

        #expect(engine.calls.last == "pause")
        #expect(player.settings.sleepTimer == .off)
    }

    @Test("Volume reaches the engine, is saved, and is restored at launch")
    func volumeSaved() {
        let player = controller()
        player.setVolume(0.4)

        #expect(engine.volume == 0.4)
        #expect(PlaybackSettingsStore(defaults: defaults).load().volume == 0.4)

        let relaunchedEngine = FakeEngine()
        _ = PlayerController(
            engine: relaunchedEngine,
            source: FakeSource(),
            queueSaver: nil,
            serverID: "srv",
            settingsStore: PlaybackSettingsStore(defaults: defaults),
            environment: .test(now: now)
        )
        #expect(relaunchedEngine.volume == 0.4)
    }

    @Test("Volume stays within 0–1")
    func volumeClamped() {
        let player = controller()
        player.setVolume(3)
        #expect(player.settings.volume == 1)
        player.setVolume(-1)
        #expect(player.settings.volume == 0)
        #expect(PlaybackSettings(volume: .nan).volume == 1)
    }

    @Test("Muting remembers the volume to go back to")
    func muteToggle() {
        let player = controller()
        player.setVolume(0.6)

        player.toggleMute()
        #expect(player.settings.volume == 0)
        #expect(engine.volume == 0)

        player.toggleMute()
        #expect(player.settings.volume == 0.6)
        #expect(engine.volume == 0.6)
    }

    @Test("Unmuting with no earlier volume goes to full volume")
    func unmuteAtLaunch() {
        let player = controller(PlaybackSettings(volume: 0))
        player.toggleMute()
        #expect(player.settings.volume == 1)
    }

    @Test("The sleep timer fades from the chosen volume and puts it back")
    func sleepFadeKeepsVolume() async throws {
        let player = try playing(["a"])
        player.setVolume(0.5)
        player.setSleepTimer(.until(now))

        player.tick()
        await player.settled()

        #expect(player.status == .paused)
        #expect(engine.volume == 0.5)
    }
}

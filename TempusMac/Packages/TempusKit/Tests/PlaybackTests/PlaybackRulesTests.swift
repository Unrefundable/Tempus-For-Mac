import Foundation
@testable import Playback
import SubsonicAPI
import Testing

@Suite("Speed and pitch")
struct PlaybackSpeedTests {
    @Test("Speed is limited to 0.25–2×, and pitch stays put unless asked")
    func defaults() {
        #expect(PlaybackSpeed().rate == 1)
        #expect(PlaybackSpeed(rate: 5).rate == 2)
        #expect(PlaybackSpeed(rate: 0.1).rate == 0.25)
        #expect(PlaybackSpeed(rate: 1.5).pitchCents == 0)
    }

    @Test("Pitch can follow the speed or be set by hand", arguments: [
        (PitchMode.followsRate, 2.0, 1200.0),
        (PitchMode.followsRate, 0.5, -1200.0),
        (PitchMode.manual(2), 1.0, 1200.0),
        (PitchMode.manual(9), 1.0, 1200.0),
    ])
    func pitch(mode: PitchMode, rate: Double, cents: Double) {
        #expect(abs(PlaybackSpeed(rate: rate, pitch: mode).pitchCents - cents) < 1e-9)
    }
}

@Suite("Sleep timer")
struct SleepTimerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A countdown ends minutes from now; zero or negative minutes is not a timer")
    func countdown() {
        #expect(SleepTimer.starting(minutes: 15, now: now) == .until(now + 900))
        #expect(SleepTimer.starting(minutes: 0, now: now) == nil)
        #expect(SleepTimer.until(now + 90).remaining(now: now) == 90)
        #expect(SleepTimer.until(now - 5).remaining(now: now) == 0)
        #expect(SleepTimer.endOfTrack.remaining(now: now) == nil)
    }

    @Test("The fade starts when the countdown runs out")
    func countdownFade() {
        #expect(!SleepTimer.until(now + 1).shouldStartFade(now: now, timeLeftInTrack: 1))
        #expect(SleepTimer.until(now).shouldStartFade(now: now, timeLeftInTrack: nil))
        #expect(!SleepTimer.off.shouldStartFade(now: now, timeLeftInTrack: 1))
    }

    @Test("End of track fades over the last 10 seconds of the track", arguments: [
        (10.0, true), (0.5, true), (10.5, false), (0.0, false), (nil, false),
    ] as [(Double?, Bool)])
    func endOfTrack(timeLeft: Double?, fades: Bool) {
        #expect(SleepTimer.endOfTrack.shouldStartFade(now: now, timeLeftInTrack: timeLeft) == fades)
    }

    @Test("On relaunch, end of track is kept and an expired countdown is dropped")
    func restore() {
        #expect(SleepTimer.endOfTrack.restored(now: now) == .endOfTrack)
        #expect(SleepTimer.until(now + 60).restored(now: now) == .until(now + 60))
        #expect(SleepTimer.until(now - 1).restored(now: now) == .off)
    }

    @Test("The fade lowers the volume in 40 steps over 10 seconds")
    func fade() {
        #expect(SleepTimer.fadeStepInterval == .milliseconds(250))
        #expect(SleepTimer.fadeVolume(afterStep: 0) == 1)
        #expect(SleepTimer.fadeVolume(afterStep: 20) == 0.5)
        #expect(SleepTimer.fadeVolume(afterStep: 40) == 0)
        #expect(SleepTimer.fadeVolume(afterStep: 99) == 0)
    }
}

@Suite("Scrobble rules")
struct ScrobblePolicyTests {
    @Test("A skipped track counts after half its length or 4 minutes, if longer than 30 seconds", arguments: [
        (31.0, 15.5, true), (31.0, 15.0, false), (30.0, 30.0, false), (600.0, 240.0, true), (600.0, 239.0, false),
    ])
    func threshold(duration: Double, position: Double, counts: Bool) {
        #expect(ScrobblePolicy.meetsThreshold(duration: duration, position: position) == counts)
    }

    @Test("Only music counts")
    func musicOnly() throws {
        #expect(try ScrobblePolicy.counts(song("a")))
        #expect(try ScrobblePolicy.counts(song("a", type: "music")))
        #expect(try !ScrobblePolicy.counts(song("a", type: "podcast")))
        #expect(try !ScrobblePolicy.counts(song("a", type: "audiobook")))
    }
}

@Suite("What to ask the server to stream")
struct StreamSettingsTests {
    @Test("Formats the player can decode are streamed as chosen")
    func playable() throws {
        let flac = try song("a", suffix: "flac")
        #expect(StreamSettings().quality(for: flac, onConstrainedNetwork: false) == .original)
        let mp3 = StreamSettings(format: .mp3, maxBitrate: 192)
        #expect(mp3.quality(for: flac, onConstrainedNetwork: false) == .transcoded(format: "mp3", maxBitrate: 192))
        #expect(StreamSettings(serverDecides: true).quality(for: flac, onConstrainedNetwork: false) == .serverDefault)
    }

    @Test("Opus, Vorbis and other formats the player can't decode are always transcoded", arguments: [
        "opus", "ogg", "oga", "wma", "ape", "wv", "OPUS",
    ])
    func unplayable(suffix: String) throws {
        let track = try song("a", suffix: suffix)
        #expect(StreamSettings().quality(for: track, onConstrainedNetwork: false) == StreamSettings.playableFallback)
        #expect(
            StreamSettings(serverDecides: true).quality(for: track, onConstrainedNetwork: false)
                == StreamSettings.playableFallback
        )
        let aac = StreamSettings(format: .aac, maxBitrate: 128)
        #expect(aac.quality(for: track, onConstrainedNetwork: false) == .transcoded(format: "aac", maxBitrate: 128))
    }

    @Test("A track with no format information is assumed playable")
    func unknown() throws {
        #expect(try StreamSettings().quality(for: song("a"), onConstrainedNetwork: false) == .original)
    }

    @Test("Hotspots and Low Data Mode use the constrained-network choice")
    func constrained() throws {
        let settings = StreamSettings(format: .original, constrainedFormat: .mp3, constrainedMaxBitrate: 128)
        let flac = try song("a", suffix: "flac")
        #expect(settings.quality(for: flac, onConstrainedNetwork: true) == .transcoded(format: "mp3", maxBitrate: 128))
        #expect(settings.quality(for: flac, onConstrainedNetwork: false) == .original)
    }
}

import Foundation
@testable import Playback
import SubsonicAPI
import Testing

/// Races and failures found in the Phase 3 review.
extension PlayerControllerTests {
    @Test("Pausing during the sleep fade cancels it, restores the volume, and resuming isn't paused again")
    func pauseDuringFade() async throws {
        let player = try playing(["a", "b"])
        player.setSleepTimer(.endOfTrack)
        engine.duration = 200
        engine.progress = 195
        player.tick() // starts the fade

        player.pause()
        player.resume()
        engine.send(.stateChanged(.playing))
        await player.settled()

        #expect(player.status == .playing)
        #expect(engine.volume == 1)
        #expect(player.settings.sleepTimer == .endOfTrack)
    }

    @Test("End of track counts time left at the playing speed", arguments: [(1.0, false), (2.0, true)])
    func endOfTrackAtSpeed(rate: Double, fades: Bool) async throws {
        let player = try playing(["a", "b"])
        player.setSpeed(PlaybackSpeed(rate: rate))
        player.setSleepTimer(.endOfTrack)
        engine.duration = 200
        engine.progress = 185 // 15 s of track: 7.5 s of real time at 2×

        player.tick()
        await player.settled()

        #expect((player.status == .paused) == fades)
    }

    @Test("When the next track fails to download ahead, the current one carries on and the bad one waits its turn")
    func upcomingFailure() throws {
        let player = try playing(["a", "b"])
        let next = player.queue.items[1]
        engine.progress = 80
        player.tick()

        engine.send(.failed(entry: next.id, message: "The server couldn't be reached."))

        #expect(engine.playedSongIDs == ["a", "a"]) // picked up again
        #expect(player.errorMessage == nil)
        try engine.send(.started(#require(player.queue.current?.id)))
        #expect(engine.calls.contains("seek 80.0"))
        #expect(engine.upcoming == nil) // not queued again ahead of time

        engine.send(.finished(player.queue.items[0].id, .ended))
        #expect(player.queue.current == next) // its turn: tried directly
        #expect(engine.playedSongIDs == ["a", "a", "b"])
    }

    @Test("A seek while the track is still buffering is applied when it starts")
    func seekWhileBuffering() throws {
        let player = controller()
        try player.play(songs("a"))
        player.seek(to: 50)
        #expect(!engine.calls.contains { $0.hasPrefix("seek") })

        try engine.send(.started(#require(player.queue.current?.id)))
        #expect(engine.calls.last == "seek 50.0")
        #expect(player.position == 50)
    }

    @Test("Starting something else counts the track that was playing, once")
    func replacingCounts() async throws {
        let player = try playing(["a", "b"])
        var events = player.events.makeAsyncIterator()
        _ = await events.next() // now playing a
        engine.duration = 200
        engine.progress = 150
        player.tick()

        try player.play(songs("x"))
        player.next() // nothing after x; must not count a again
        try player.play(songs("y"))

        #expect(try await events.next() == .played(song("a"), at: now))
        try engine.send(.started(#require(player.queue.current?.id)))
        #expect(try await events.next() == .nowPlaying(song("y")))
    }

    @Test("A track that ended isn't counted again by a skip before the next one starts")
    func noDoubleCount() async throws {
        let player = try playing(["a", "b", "c"])
        var events = player.events.makeAsyncIterator()
        _ = await events.next() // now playing a
        engine.duration = 200
        engine.progress = 199
        player.tick()

        engine.send(.finished(player.queue.items[0].id, .ended))
        player.next() // before the next track's start arrives
        try engine.send(.started(#require(player.queue.current?.id)))

        #expect(try await events.next() == .played(song("a"), at: now))
        #expect(try await events.next() == .nowPlaying(song("b")))
    }
}

/// A dead stream must not buffer forever: AudioStreaming never reports it.
extension PlayerControllerTests {
    @Test("A stream that never starts stops with a message after the start timeout")
    func streamThatNeverStarts() async throws {
        let player = controller()
        player.startTimeout = .milliseconds(20)
        try player.play([song("a")])
        #expect(player.status == .buffering)

        try await Task.sleep(for: .milliseconds(200))

        #expect(player.status == .paused)
        #expect(player.errorMessage != nil)
    }

    @Test("A stream that starts in time keeps playing")
    func streamThatStartsInTime() async throws {
        let player = controller()
        player.startTimeout = .milliseconds(50)
        try player.play([song("a")])
        try engine.send(.started(#require(player.queue.currentID)))
        engine.send(.stateChanged(.playing))

        try await Task.sleep(for: .milliseconds(200))

        #expect(player.status == .playing)
        #expect(player.errorMessage == nil)
    }
}

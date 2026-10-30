import Foundation
import Persistence
@testable import Playback
import SubsonicAPI
import Testing

@MainActor
@Suite("Player controller")
struct PlayerControllerTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let engine = FakeEngine()
    let saver = FakeQueueSaver()
    let defaults = UserDefaults(suiteName: "PlayerControllerTests-\(UUID().uuidString)") ?? .standard

    func controller(_ settings: PlaybackSettings = PlaybackSettings()) -> PlayerController {
        let store = PlaybackSettingsStore(defaults: defaults)
        store.save(settings)
        return PlayerController(
            engine: engine,
            source: FakeSource(),
            queueSaver: saver,
            serverID: "srv",
            settingsStore: store,
            environment: .test(now: now)
        )
    }

    /// Plays `ids` from `index` and lets the engine start it.
    func playing(
        _ ids: [String],
        at index: Int = 0,
        settings: PlaybackSettings = PlaybackSettings()
    ) throws -> PlayerController {
        let player = controller(settings)
        try player.play(ids.map { try song($0) }, startingAt: index)
        try engine.send(.started(#require(player.queue.current?.id)))
        engine.send(.stateChanged(.playing))
        return player
    }

    @Test("Playing a list streams the chosen track and readies the next one")
    func play() async throws {
        let player = try playing(["a", "b", "c"], at: 1)

        #expect(engine.playedSongIDs == ["b"])
        #expect(engine.upcoming?.url.lastPathComponent == "c")
        #expect(player.status == .playing)
        await player.settled()
        #expect(saver.queues.last?.songs.map(\.id) == ["a", "b", "c"])
        #expect(saver.queues.last?.currentIndex == 1)
    }

    @Test("A gapless transition moves the queue on, counts the play and readies the one after")
    func gaplessTransition() async throws {
        let player = try playing(["a", "b", "c"])
        var events = player.events.makeAsyncIterator()
        let second = player.queue.items[1]

        engine.send(.finished(player.queue.items[0].id, .ended))
        engine.send(.started(second.id))

        #expect(player.queue.current == second)
        #expect(engine.upcoming?.url.lastPathComponent == "c")
        #expect(engine.playedSongIDs == ["a"]) // no new stream: it was already queued
        #expect(try await events.next() == .nowPlaying(song("a")))
        #expect(try await events.next() == .played(song("a"), at: now))
        #expect(try await events.next() == .nowPlaying(song("b")))
    }

    @Test("The last track ending stops playback; play then starts it again")
    func endOfQueue() throws {
        let player = try playing(["a"])
        engine.send(.finished(player.queue.items[0].id, .ended))

        #expect(player.status == .stopped)
        player.resume()
        #expect(engine.playedSongIDs == ["a", "a"])
    }

    @Test("Skipping counts the track only past the scrobble threshold", arguments: [(150.0, true), (10.0, false)])
    func skipThreshold(position: Double, counts: Bool) async throws {
        let player = try playing(["a", "b"])
        var events = player.events.makeAsyncIterator()
        _ = await events.next() // now playing a
        engine.duration = 200
        engine.progress = position
        player.tick()

        player.next()

        #expect(engine.playedSongIDs == ["a", "b"])
        try engine.send(.started(#require(player.queue.current?.id)))
        let expected: PlaybackEvent = try counts ? .played(song("a"), at: now) : .nowPlaying(song("b"))
        #expect(await events.next() == expected)
    }

    @Test("Skipping while paused moves to the track without starting it")
    func skipWhilePaused() throws {
        let player = try playing(["a", "b"])
        player.pause()

        player.next()

        #expect(player.queue.current?.song.id == "b")
        #expect(player.status == .paused)
        #expect(engine.playedSongIDs == ["a"])
        player.resume()
        #expect(engine.playedSongIDs == ["a", "b"])
    }

    @Test("Previous restarts a track after 3 seconds, and goes back before that")
    func previous() throws {
        let player = try playing(["a", "b"], at: 1)
        engine.progress = 10
        player.tick()
        player.previous()
        #expect(engine.calls.last == "seek 0.0")
        #expect(player.queue.current?.song.id == "b")

        engine.progress = 2
        player.tick()
        player.previous()
        #expect(player.queue.current?.song.id == "a")
        #expect(engine.playedSongIDs == ["b", "a"])
    }

    @Test("Repeat one readies the same entry again; the repeat button updates what comes next")
    func repeatModes() throws {
        let player = try playing(["a", "b"], at: 1)
        #expect(engine.upcoming == nil)

        player.cycleRepeatMode() // all
        #expect(engine.upcoming?.url.lastPathComponent == "a")
        player.cycleRepeatMode() // one
        #expect(engine.upcoming?.id == player.queue.current?.id)
        #expect(player.settings.repeatMode == .one)
        #expect(PlaybackSettingsStore(defaults: defaults).load().repeatMode == .one)
    }

    @Test("Shuffle keeps the current track playing and readies a new next track")
    func shuffle() throws {
        let player = try playing(["a", "b", "c", "d", "e", "f"])
        player.toggleShuffle()

        #expect(player.queue.isShuffled)
        #expect(player.queue.current?.song.id == "a")
        #expect(engine.upcoming?.id == player.queue.items[1].id)
        player.toggleShuffle()
        #expect(engine.upcoming?.url.lastPathComponent == "b")
    }

    @Test("Queue edits keep the next track right", arguments: [true, false])
    func edits(insertNext: Bool) throws {
        let player = try playing(["a", "b"])
        if insertNext {
            try player.playNext([song("x")])
            #expect(engine.upcoming?.url.lastPathComponent == "x")
        } else {
            player.remove(player.queue.items[1].id)
            #expect(engine.upcoming == nil)
        }
    }

    @Test("Adding to an empty player starts playing")
    func addToEmpty() throws {
        let player = controller()
        try player.addToQueue([song("x")])
        #expect(engine.playedSongIDs == ["x"])
    }

    @Test("Pausing saves the position")
    func pauseSaves() async throws {
        let player = try playing(["a", "b"], at: 1)
        engine.progress = 42.5
        player.tick()

        player.pause()

        await player.settled()
        #expect(engine.calls.last == "pause")
        #expect(saver.progress.last == FakeQueueSaver.Progress(index: 1, milliseconds: 42500))
    }

    @Test("A restored queue waits, paused, and resumes where it left off")
    func restore() throws {
        let player = controller()
        try player.restore(SavedQueue(songs: songs("a", "b"), currentIndex: 1, positionMilliseconds: 30000))

        #expect(player.status == .paused)
        #expect(player.position == 30)
        #expect(engine.played.isEmpty)

        player.resume()
        try engine.send(.started(#require(player.queue.current?.id)))
        #expect(engine.playedSongIDs == ["b"])
        #expect(engine.calls.contains("seek 30.0"))
    }

    @Test("A failed stream pauses with a message, and play retries from the same spot")
    func failure() throws {
        let player = try playing(["a"])
        engine.progress = 12
        player.tick()

        engine.send(.failed(entry: player.queue.current?.id, message: "The server couldn't be reached."))

        #expect(player.status == .paused)
        #expect(player.errorMessage == "The server couldn't be reached.")
        player.resume()
        try engine.send(.started(#require(player.queue.current?.id)))
        #expect(engine.playedSongIDs == ["a", "a"])
        #expect(engine.calls.contains("seek 12.0"))
        #expect(player.errorMessage == nil)
    }

    @Test("Choosing a queue entry plays it; stop forgets the position")
    func jumpAndStop() throws {
        let player = try playing(["a", "b", "c"])
        player.jump(to: player.queue.items[2].id)
        #expect(engine.playedSongIDs == ["a", "c"])

        player.stop()
        #expect(player.status == .stopped)
        #expect(player.position == 0)
        #expect(engine.calls.last == "stop")
    }

    @Test("Seeking stays within the track")
    func seekBounds() throws {
        let player = try playing(["a"])
        player.seek(to: 999)
        #expect(player.position == 200)
        player.seek(to: -5)
        #expect(engine.calls.last == "seek 0.0")
    }

    @Test("Moving and shuffling upcoming tracks keep the current one")
    func reorder() throws {
        let player = try playing(["a", "b", "c", "d"])
        player.move(player.queue.items[3].id, to: 1)
        #expect(engine.upcoming?.url.lastPathComponent == "d")

        player.shuffleUpcoming()
        #expect(player.queue.current?.song.id == "a")
        #expect(engine.upcoming?.id == player.queue.items[1].id)
    }

    @Test("Shuffle play starts from the top of a shuffled copy of the list")
    func playShuffled() throws {
        let player = controller()
        try player.playShuffled(songs("a", "b", "c", "d", "e"))
        #expect(Set(player.queue.items.map(\.song.id)) == ["a", "b", "c", "d", "e"])
        #expect(player.queue.currentIndex == 0)
        #expect(!player.queue.isShuffled)
    }
}

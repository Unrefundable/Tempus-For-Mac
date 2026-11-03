@testable import AppCore
import Foundation
import Persistence
import Playback
import SubsonicAPI
import Synchronization
import Testing

/// Stands in for the waits between reconnect attempts: records each one and returns at once, or
/// holds it until a gate opens. An action can run on each wait, to change what the server answers.
final class SleepRecorder: Sendable {
    private struct State {
        var delays: [Duration] = []
        var action: (@Sendable (Int) -> Void)?
        var gate: PingGate?
    }

    private let state = Mutex(State())

    var delays: [Duration] {
        state.withLock { $0.delays }
    }

    /// Runs `action` with the number of waits so far, each time a wait starts.
    func onSleep(_ action: @escaping @Sendable (Int) -> Void) {
        state.withLock { $0.action = action }
    }

    /// Holds every wait until `gate` opens.
    func hold(until gate: PingGate) {
        state.withLock { $0.gate = gate }
    }

    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] duration in
            let current = state.withLock { state in
                state.delays.append(duration)
                return state
            }
            current.action?(current.delays.count)
            await current.gate?.wait()
            try Task.checkCancellation()
        }
    }
}

extension AppModelTests {
    /// Yields until `condition` holds, giving up after a bounded number of tries.
    func waitUntil(_ condition: () -> Bool) async {
        for _ in 0 ..< 10000 where !condition() {
            await Task.yield()
        }
    }

    @Test
    func `an offline session reconnects by itself once the server answers`() async throws {
        let profile = try await accounts().save(TestData.validServer(), replacing: nil)
        pings.set(TestData.address, .failure(.transport(.notConnectedToInternet)))
        sleeper.onSleep { [pings] count in
            if count == 2 {
                pings.set(TestData.address, .success(PingStub.info))
            }
        }
        let model = makeModel()

        await model.connect(to: profile)
        #expect(model.session?.isOffline == true)
        #expect(model.reconnectStatus == .retrying)
        await model.reconnectTask?.value

        #expect(model.phase == .signedIn)
        #expect(model.session?.profile == profile)
        #expect(model.session?.isOffline == false)
        #expect(model.reconnectStatus == .idle)
        #expect(sleeper.delays == Array(ReconnectPolicy.standard.delays.prefix(2)))
    }

    @Test
    func `coming back online keeps the queue where it was, paused`() async throws {
        let profile = try await accounts().save(TestData.validServer(), replacing: nil)
        let saved = SavedQueue(
            songs: [TestData.song("1"), TestData.song("2")],
            currentIndex: 1,
            positionMilliseconds: 5000
        )
        try await QueueStore(database: database).save(saved, server: profile.id)
        pings.set(TestData.address, .failure(.transport(.timedOut)))
        sleeper.onSleep { [pings] _ in pings.set(TestData.address, .success(PingStub.info)) }
        let model = makeModel()

        await model.connect(to: profile)
        await model.reconnectTask?.value

        let player = try #require(model.session?.player)
        #expect(model.session?.isOffline == false)
        #expect(player.queue.items.map(\.song.id) == ["1", "2"])
        #expect(player.queue.currentIndex == 1)
        #expect(player.status == .paused)
    }

    @Test
    func `retries stop after the last attempt and leave the session offline`() async throws {
        let profile = try await accounts().save(TestData.validServer(), replacing: nil)
        pings.set(TestData.address, .failure(.transport(.cannotConnectToHost)))
        let model = makeModel()

        await model.connect(to: profile)
        await model.reconnectTask?.value
        let asked = pings.asked.count
        for _ in 0 ..< 100 {
            await Task.yield()
        }

        #expect(sleeper.delays == ReconnectPolicy.standard.delays)
        #expect(model.session?.isOffline == true)
        #expect(model.reconnectStatus == .idle)
        #expect(pings.asked.count == asked)
    }

    @Test
    func `a network change gives an offline session a fresh round of retries`() async throws {
        let profile = try await accounts().save(TestData.validServer(), replacing: nil)
        pings.set(TestData.address, .failure(.transport(.notConnectedToInternet)))
        let model = makeModel()
        await model.connect(to: profile)
        await model.reconnectTask?.value
        #expect(model.reconnectStatus == .idle)

        pings.set(TestData.address, .success(PingStub.info))
        model.networkChanged()
        #expect(model.reconnectStatus == .retrying)
        await model.reconnectTask?.value

        #expect(model.session?.isOffline == false)
        #expect(model.reconnectStatus == .idle)
    }

    @Test
    func `an online session never retries`() async throws {
        let profile = try await accounts().save(TestData.validServer(), replacing: nil)
        let model = makeModel()
        await model.connect(to: profile)

        model.networkChanged()

        #expect(model.reconnectStatus == .idle)
        #expect(model.reconnectTask == nil)
        #expect(sleeper.delays.isEmpty)
    }

    @Test
    func `coming back online waits for playback to pause`() async throws {
        let profile = try await accounts().save(TestData.validServer(), replacing: nil)
        pings.set(TestData.address, .failure(.transport(.notConnectedToInternet)))
        sleeper.onSleep { [pings] _ in pings.set(TestData.address, .success(PingStub.info)) }
        let model = makeModel()
        await model.connect(to: profile)
        let offline = try #require(model.session)
        offline.player.play([TestData.song("1")])

        await model.reconnectTask?.value

        #expect(model.reconnectStatus == .waitingForPause)
        #expect(model.session === offline)
        #expect(!engine.calls.contains("pause"))

        offline.player.pause()
        await waitUntil { model.session?.isOffline == false && model.reconnectStatus == .idle }

        #expect(model.session?.isOffline == false)
        #expect(model.session?.player.queue.items.map(\.song.id) == ["1"])
        #expect(model.reconnectStatus == .idle)
    }

    @Test
    func `signing out while waiting for a pause leaves nothing to switch later`() async throws {
        let profile = try await accounts().save(TestData.validServer(), replacing: nil)
        pings.set(TestData.address, .failure(.transport(.notConnectedToInternet)))
        sleeper.onSleep { [pings] _ in pings.set(TestData.address, .success(PingStub.info)) }
        let model = makeModel()
        await model.connect(to: profile)
        let offline = try #require(model.session)
        offline.player.play([TestData.song("1")])
        await model.reconnectTask?.value
        #expect(model.reconnectStatus == .waitingForPause)

        await model.signOut() // pauses the old player, which fires its observer
        for _ in 0 ..< 100 {
            await Task.yield()
        }

        #expect(model.phase == .signedOut)
        #expect(model.session == nil)
        #expect(model.reconnectStatus == .idle)
        #expect(model.reconnectTask == nil)
    }

    @Test
    func `signing out stops the retries`() async throws {
        let profile = try await accounts().save(TestData.validServer(), replacing: nil)
        pings.set(TestData.address, .failure(.transport(.notConnectedToInternet)))
        let gate = PingGate()
        sleeper.hold(until: gate)
        let model = makeModel()
        await model.connect(to: profile)
        let retries = try #require(model.reconnectTask)
        await waitUntil { !sleeper.delays.isEmpty }
        let asked = pings.asked.count

        await model.signOut()
        gate.open()
        await retries.value

        #expect(model.phase == .signedOut)
        #expect(model.session == nil)
        #expect(model.reconnectStatus == .idle)
        #expect(pings.asked.count == asked)
    }

    @Test
    func `connecting by hand replaces the retries in progress`() async throws {
        let profile = try await accounts().save(TestData.validServer(), replacing: nil)
        pings.set(TestData.address, .failure(.transport(.notConnectedToInternet)))
        let gate = PingGate()
        sleeper.hold(until: gate)
        let model = makeModel()
        await model.connect(to: profile)
        let retries = try #require(model.reconnectTask)
        await waitUntil { !sleeper.delays.isEmpty }

        pings.set(TestData.address, .success(PingStub.info))
        await model.connect(to: profile)
        let online = try #require(model.session)
        gate.open()
        await retries.value

        #expect(model.session === online)
        #expect(online.isOffline == false)
        #expect(model.reconnectStatus == .idle)
    }

    @Test
    func `a server that refuses the account stops the retries and stays offline`() async throws {
        let profile = try await accounts().save(TestData.validServer(), replacing: nil)
        pings.set(TestData.address, .failure(.transport(.notConnectedToInternet)))
        sleeper.onSleep { [pings] _ in
            pings.set(TestData.address, .failure(.server(code: .wrongCredentials, message: nil)))
        }
        let model = makeModel()

        await model.connect(to: profile)
        await model.reconnectTask?.value

        #expect(sleeper.delays.count == 1)
        #expect(model.phase == .signedIn)
        #expect(model.session?.isOffline == true)
        #expect(model.reconnectStatus == .idle)
    }
}

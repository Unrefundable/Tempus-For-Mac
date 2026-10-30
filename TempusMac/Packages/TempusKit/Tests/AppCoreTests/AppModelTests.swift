@testable import AppCore
import Foundation
import Persistence
import Playback
import SecureStorage
import SubsonicAPI
import Testing

@MainActor
struct AppModelTests {
    let database: AppDatabase
    let keychain = MemorySecretStore()
    let pings = PingStub()
    let defaults: UserDefaults
    let engine = FakeEngine()

    init() throws {
        database = try AppDatabase.inMemory()
        defaults = try #require(UserDefaults(suiteName: "AppModelTests.\(UUID().uuidString)"))
    }

    func makeModel() -> AppModel {
        let environment = AppEnvironment(
            database: database,
            secrets: ServerSecretStore(store: keychain),
            tester: pings.tester,
            defaults: defaults,
            settingsStore: PlaybackSettingsStore(defaults: defaults),
            artworkCaches: .inMemory,
            isOnConstrainedNetwork: { false }
        )
        return AppModel(environment: environment, engine: engine)
    }

    func accounts() -> AccountService {
        AccountService(database: database, secrets: ServerSecretStore(store: keychain), tester: pings.tester)
    }

    @Test
    func `launching with no servers asks for one`() async {
        let model = makeModel()
        await model.launch()
        #expect(model.phase == .signedOut)
        #expect(model.servers.isEmpty)
        #expect(model.session == nil)
    }

    @Test
    func `saving the first server signs in to it`() async throws {
        let model = makeModel()
        await model.launch()

        let profile = try await model.save(TestData.validServer(), replacing: nil)

        #expect(model.phase == .signedIn)
        #expect(model.servers.map(\.id) == [profile.id])
        #expect(model.session?.profile.id == profile.id)
        #expect(model.session?.isOffline == false)
        #expect(engine.calls.contains("setPolicy"))
    }

    @Test
    func `launch reconnects to the last server and restores its queue paused`() async throws {
        let profile = try await accounts().save(TestData.validServer(), replacing: nil)
        let saved = SavedQueue(
            songs: [TestData.song("1"), TestData.song("2")],
            currentIndex: 1,
            positionMilliseconds: 5000
        )
        try await QueueStore(database: database).save(saved, server: profile.id)
        await makeModel().connect(to: profile) // remembers it as the last server

        let model = makeModel()
        await model.launch()

        #expect(model.phase == .signedIn)
        let player = try #require(model.session?.player)
        #expect(player.queue.items.map(\.song.id) == ["1", "2"])
        #expect(player.queue.currentIndex == 1)
        #expect(player.status == .paused)
    }

    @Test
    func `wrong credentials keep the server list up with the reason`() async throws {
        let profile = try await accounts().save(TestData.validServer(), replacing: nil)
        pings.set(TestData.address, .failure(.server(code: .wrongCredentials, message: nil)))
        let model = makeModel()

        await model.connect(to: profile)

        #expect(model.phase == .signedOut)
        #expect(model.errorMessage == "Wrong username or password.")
    }

    @Test
    func `an unreachable server still opens, offline, from the cache`() async throws {
        let profile = try await accounts().save(TestData.validServer(), replacing: nil)
        pings.set(TestData.address, .failure(.transport(.notConnectedToInternet)))
        let model = makeModel()

        await model.connect(to: profile)

        #expect(model.phase == .signedIn)
        #expect(model.session?.isOffline == true)
    }

    @Test
    func `deleting the current server signs out and removes its secrets`() async throws {
        let model = makeModel()
        await model.launch()
        let profile = try await model.save(TestData.validServer(), replacing: nil)

        try await model.delete(profile)

        #expect(model.phase == .signedOut)
        #expect(model.servers.isEmpty)
        #expect(model.session == nil)
        #expect(keychain.keys.isEmpty)
        #expect(engine.policyServers.last == .some(nil))
    }

    @Test
    func `switching servers pauses the old player before the engine changes hands`() async throws {
        let model = makeModel()
        await model.launch()
        let first = try await model.save(TestData.validServer(), replacing: nil)
        let second = try await accounts().save(TestData.validServer(TestData.form(name: "Two")), replacing: nil)
        model.session?.player.play([TestData.song("1")])

        await model.connect(to: second)

        #expect(model.session?.profile == second)
        #expect(model.session?.profile != first)
        let pause = try #require(engine.calls.lastIndex(of: "pause"))
        let handover = try #require(engine.calls.lastIndex(of: "setPolicy"))
        #expect(pause < handover)
    }

    @Test
    func `signing out keeps the servers and leaves the engine without a policy`() async throws {
        let model = makeModel()
        await model.launch()
        _ = try await model.save(TestData.validServer(), replacing: nil)

        await model.signOut()

        #expect(model.phase == .signedOut)
        #expect(model.servers.count == 1)
        #expect(engine.policyServers.last == .some(nil))
    }

    @Test
    func `termination waits for the player to settle`() async throws {
        let model = makeModel()
        await model.launch()
        _ = try await model.save(TestData.validServer(), replacing: nil)
        model.session?.player.play([TestData.song("1")])

        await model.prepareForTermination()

        let saved = try await QueueStore(database: database).load(server: #require(model.session?.profile.id))
        #expect(saved?.songs.map(\.id) == ["1"])
    }

    @Test
    func `an offline session never uses a remembered address the profile no longer has`() async throws {
        let profile = try await accounts().save(TestData.validServer(), replacing: nil)
        defaults.set("http://10.9.9.9", forKey: AppModel.addressKeyPrefix + profile.id)
        pings.set(TestData.address, .failure(.transport(.timedOut)))
        let model = makeModel()

        await model.connect(to: profile)

        #expect(model.session?.isOffline == true)
        #expect(model.session?.client.server == profile.address)
    }

    @Test
    func `the local address must answer as a Subsonic server before credentials move to it`() async throws {
        var form = TestData.form()
        form.usesLocalAddress = true
        form.localAddress = "http://192.168.1.10"
        let profile = try await accounts().save(TestData.validServer(form), replacing: nil)
        pings.set("http://192.168.1.10", .failure(.httpStatus(401))) // anyone can answer 401
        let model = makeModel()

        await model.connect(to: profile)

        #expect(model.session?.client.server == profile.address)
    }

    @Test
    func `saving a server forgets the address it was last reached on`() async throws {
        let model = makeModel()
        await model.launch()
        let profile = try await model.save(TestData.validServer(), replacing: nil)
        defaults.set("http://10.9.9.9", forKey: AppModel.addressKeyPrefix + profile.id)

        _ = try await model.save(TestData.validServer(TestData.form(name: "Renamed")), replacing: profile)

        #expect(defaults.string(forKey: AppModel.addressKeyPrefix + profile.id) != "http://10.9.9.9")
    }

    @Test
    func `launching again, as when the window reopens, leaves the session and playback alone`() async throws {
        let model = makeModel()
        await model.launch()
        _ = try await model.save(TestData.validServer(), replacing: nil)
        let session = try #require(model.session)
        session.player.play([TestData.song("1")])

        await model.launch()

        #expect(model.session === session)
        #expect(session.player.status != .paused)
    }

    @Test
    func `an ended session is released`() async throws {
        let model = makeModel()
        await model.launch()
        _ = try await model.save(TestData.validServer(), replacing: nil)
        weak var ended = model.session
        model.session?.player.play([TestData.song("1")])

        await model.signOut()

        #expect(ended == nil)
    }

    @Test
    func `overlapping connects end on the last one, with a session in place`() async throws {
        let first = try await accounts().save(TestData.validServer(), replacing: nil)
        let second = try await accounts().save(TestData.validServer(TestData.form(name: "Two")), replacing: nil)
        let model = makeModel()
        await model.connect(to: first)

        async let toSecond: Void = model.connect(to: second)
        async let toFirst: Void = model.connect(to: first)
        _ = await (toSecond, toFirst)

        #expect(model.phase == .signedIn)
        #expect(model.session != nil)
        #expect(engine.policyServers.last != .some(nil))
    }
}

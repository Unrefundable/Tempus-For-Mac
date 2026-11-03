@testable import AppCore
import Foundation
import Persistence
import Playback
import SecureStorage
import SubsonicAPI
import Synchronization
import Testing

/// Holds pings until opened, so a test can act while a connect is in flight.
final class PingGate: Sendable {
    private let waiters = Mutex<(isOpen: Bool, continuations: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = waiters.withLock { state in
                if state.isOpen {
                    return true
                }
                state.continuations.append(continuation)
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    func open() {
        let pending = waiters.withLock { state in
            state.isOpen = true
            defer { state.continuations = [] }
            return state.continuations
        }
        pending.forEach { $0.resume() }
    }
}

extension AppModelTests {
    @Test
    func `cancelling a connect while the server answers stays signed out`() async throws {
        let profile = try await accounts().save(TestData.validServer(), replacing: nil)
        let gate = PingGate()
        let environment = AppEnvironment(
            database: database,
            secrets: ServerSecretStore(store: keychain),
            tester: ConnectionTester { _ in
                await gate.wait()
                return PingStub.info
            },
            defaults: defaults,
            settingsStore: PlaybackSettingsStore(defaults: defaults),
            artworkCaches: .inMemory
        )
        let model = AppModel(environment: environment, engine: engine)
        let connecting = Task { await model.connect(to: profile) }
        while model.phase != .connecting(profile) {
            await Task.yield()
        }

        await model.signOut()
        gate.open()
        await connecting.value

        #expect(model.phase == .signedOut)
        #expect(model.session == nil)
        #expect(defaults.string(forKey: AppModel.lastServerKey) == nil)
    }
}

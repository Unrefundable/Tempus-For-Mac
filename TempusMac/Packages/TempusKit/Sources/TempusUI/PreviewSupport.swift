import AppCore
import Foundation
import Persistence
import Playback
import SecureStorage
import SubsonicAPI
import Synchronization

/// Models for SwiftUI previews: an in-memory database and keychain, a silent engine, and a server
/// that always answers.
@MainActor
enum PreviewSupport {
    static let songs = [
        Song(
            id: "1",
            title: "Hold On",
            album: "Sound & Color",
            artist: "Alabama Shakes",
            suffix: "flac",
            duration: 228,
            bitrate: 1411,
            samplingRate: 44100,
            bitDepth: 16
        ),
        Song(id: "2", title: "Gimme All Your Love", album: "Sound & Color", artist: "Alabama Shakes", duration: 243),
        Song(id: "3", title: "Future People", album: "Sound & Color", artist: "Alabama Shakes", duration: 202),
    ]

    static var form: ServerForm {
        var form = ServerForm()
        form.name = "Home"
        form.username = "alice"
        form.password = "preview"
        form.address = "https://music.example.com"
        return form
    }

    /// Signed out, or signed in with a queue playing from the preview songs.
    static func model(signedIn: Bool) -> AppModel {
        // An in-memory database can only fail if SQLite itself is broken.
        // swiftlint:disable:next force_try
        let database = try! AppDatabase.inMemory()
        let defaults = UserDefaults(suiteName: "TempusPreview") ?? .standard
        let environment = AppEnvironment(
            database: database,
            secrets: ServerSecretStore(store: MemorySecrets()),
            tester: ConnectionTester { _ in
                ServerInfo(apiVersion: "1.16.1", type: "navidrome", serverVersion: "0.64.2", isOpenSubsonic: true)
            },
            defaults: defaults,
            settingsStore: PlaybackSettingsStore(defaults: defaults),
            artworkCaches: .inMemory
        )
        let model = AppModel(environment: environment, engine: SilentEngine())
        Task {
            await model.launch()
            guard signedIn, let server = try? form.validated().get() else { return }
            _ = try? await model.save(server, replacing: nil)
            model.session?.player.play(songs)
            model.session?.player.pause()
        }
        return model
    }
}

private final class MemorySecrets: SecretStore {
    private let items = Mutex<[String: Data]>([:])

    func data(for key: String) throws(SecretStoreError) -> Data? {
        items.withLock { $0[key] }
    }

    func set(_ data: Data, for key: String) throws(SecretStoreError) {
        items.withLock { $0[key] = data }
    }

    func removeData(for key: String) throws(SecretStoreError) {
        _ = items.withLock { $0.removeValue(forKey: key) }
    }
}

/// Plays nothing; reports each entry as started so the player shows it.
@MainActor
private final class SilentEngine: PolicySwitchingEngine {
    var onEvent: (@MainActor (EngineEvent) -> Void)?
    var progress: TimeInterval = 42
    var duration: TimeInterval = 228
    var volume: Float = 1

    func setPolicy(_: MediaRequestPolicy?) {}

    func play(_ item: EngineItem) {
        onEvent?(.started(item.id))
    }

    func setUpcoming(_: EngineItem?) {}
    func pause() {}
    func resume() {}
    func stop() {}
    func seek(to _: TimeInterval) {}
    func apply(speed _: PlaybackSpeed) {}
    func apply(equalizer _: EqualizerSettings) {}
    func setGain(decibels _: Double) {}
}

import Foundation
import Persistence
import Playback
import SecureStorage

public extension AppModel {
    /// The app's model on real services: the database in Application Support, secrets in the
    /// Keychain, covers in Caches, one streaming engine, the system's Now Playing (mirrored to
    /// Discord when that's on), and the network and output-device monitors.
    static func live() throws -> AppModel {
        let files = FileManager.default
        let support = try files.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let caches = try files.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let database = try AppDatabase.open(at: support.appending(path: "Tempus/Tempus.sqlite"))

        let network = NetworkMonitor()
        let environment = AppEnvironment(
            database: database,
            secrets: ServerSecretStore(),
            artworkCaches: .onDisk(at: caches.appending(path: "Artwork", directoryHint: .isDirectory)),
            isOnConstrainedNetwork: { network.isConstrained },
            downloadsDirectory: support.appending(path: "Tempus/Downloads", directoryHint: .isDirectory)
        )
        let nowPlaying = SystemNowPlaying()
        let discord = DiscordPresence(settings: environment.settings)
        nowPlaying.mirror = discord
        let model = AppModel(environment: environment, engine: StreamingEngine(), nowPlaying: nowPlaying)
        model.discord = discord

        // Pause when the output in use disappears (headphones unplugged, Bluetooth gone), as Music does.
        let output = OutputDeviceMonitor()
        output.onOutputLost = { [weak model] in model?.session?.player.pause() }
        network.onChange = { [weak model] in model?.networkChanged() }
        model.networkMonitor = network
        model.outputMonitor = output
        return model
    }
}

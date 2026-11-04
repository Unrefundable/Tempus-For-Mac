import Foundation
import Observation
import os
import Persistence
import Playback
import SecureStorage
import SubsonicAPI

/// The services the app model runs on, replaceable in tests and previews.
@MainActor
public struct AppEnvironment {
    public let database: AppDatabase
    public let secrets: ServerSecretStore
    public let tester: ConnectionTester
    /// Non-secret state: the last server used and the address it answered on.
    public let defaults: UserDefaults
    public let settingsStore: PlaybackSettingsStore
    public let artworkCaches: ArtworkCaches
    public let isOnConstrainedNetwork: @MainActor @Sendable () -> Bool
    public let settings: AppSettings
    /// Where downloaded tracks go, one folder per server.
    public let downloadsDirectory: URL
    public let downloader: any FileDownloading
    /// When an offline session tries its server again, and how it waits in between.
    public let reconnectPolicy: ReconnectPolicy
    public let sleep: @Sendable (Duration) async throws -> Void

    public init(
        database: AppDatabase,
        secrets: ServerSecretStore,
        tester: ConnectionTester = .live,
        defaults: UserDefaults = .standard,
        settingsStore: PlaybackSettingsStore = PlaybackSettingsStore(),
        artworkCaches: ArtworkCaches,
        isOnConstrainedNetwork: @escaping @MainActor @Sendable () -> Bool = { false },
        settings: AppSettings? = nil,
        downloadsDirectory: URL = FileManager.default.temporaryDirectory.appending(path: "TempusDownloads"),
        downloader: (any FileDownloading)? = nil,
        reconnectPolicy: ReconnectPolicy = .standard,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.database = database
        self.secrets = secrets
        self.tester = tester
        self.defaults = defaults
        self.settingsStore = settingsStore
        self.artworkCaches = artworkCaches
        self.isOnConstrainedNetwork = isOnConstrainedNetwork
        self.settings = settings ?? AppSettings(defaults: defaults)
        self.downloadsDirectory = downloadsDirectory
        self.downloader = downloader ?? URLSessionDownloader()
        self.reconnectPolicy = reconnectPolicy
        self.sleep = sleep
    }
}

/// The app's state: which servers exist, which one is in use, and its session. One engine serves
/// every session; switching servers saves the old player's place, then hands the engine over.
@MainActor
@Observable
public final class AppModel {
    public enum Phase: Sendable, Equatable {
        case launching
        /// Show the server list (or the editor when there are none).
        case signedOut
        case connecting(ServerProfile)
        case signedIn
    }

    static let lastServerKey = "lastServerID"
    static let addressKeyPrefix = "addressInUse."
    static let logger = Logger(subsystem: "io.github.unrefundable.TempusMac", category: "AppModel")

    public private(set) var phase = Phase.launching
    public private(set) var servers: [ServerProfile] = []
    public private(set) var session: ServerSession?
    /// Why the last connection failed, for the server list. Safe to show.
    public private(set) var errorMessage: String?
    public internal(set) var reconnectStatus = ReconnectStatus.idle

    @ObservationIgnored public let accounts: AccountService
    @ObservationIgnored let environment: AppEnvironment
    @ObservationIgnored private let engine: any PolicySwitchingEngine
    @ObservationIgnored private let nowPlaying: SystemNowPlaying?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    /// The song whose cover the system's Now Playing has, so queue edits don't reload it.
    @ObservationIgnored private var artworkSongID: String?
    /// Bumped by each connect, so a slow one that is overtaken leaves the newer one alone.
    @ObservationIgnored private var connection = 0
    @ObservationIgnored private var hasLaunched = false
    /// The round of retries in progress, if any (see `ReconnectPolicy`).
    @ObservationIgnored var reconnectTask: Task<Void, Never>?
    /// Bumped by each new round and each connect, so a stale round or observer stops at its next check.
    @ObservationIgnored var reconnectRound = 0
    /// System monitors that live as long as the model (`AppModel.live()`).
    @ObservationIgnored var networkMonitor: NetworkMonitor?
    @ObservationIgnored var outputMonitor: OutputDeviceMonitor?
    /// The Discord status, for its settings. Nil where nothing reaches Discord, as in tests.
    @ObservationIgnored public internal(set) var discord: DiscordPresence?

    public init(environment: AppEnvironment, engine: any PolicySwitchingEngine, nowPlaying: SystemNowPlaying? = nil) {
        self.environment = environment
        self.engine = engine
        self.nowPlaying = nowPlaying
        accounts = AccountService(
            database: environment.database,
            secrets: environment.secrets,
            tester: environment.tester
        )
    }

    // MARK: Launch and servers

    /// Prunes old cached data, then reconnects to the last server used, or asks for one. Runs once:
    /// the window's content calls it, and reopening the window must not interrupt playback.
    public func launch() async {
        guard !hasLaunched else { return }
        hasLaunched = true
        await LaunchMaintenance(database: environment.database).run()
        await reloadServers()
        guard let id = environment.defaults.string(forKey: Self.lastServerKey),
              let profile = servers.first(where: { $0.id == id })
        else {
            phase = .signedOut
            return
        }
        await connect(to: profile)
    }

    /// Saves a server (keeping `existing`'s id), then signs in to it from the server list, or again
    /// when it is the server in use. The address it was last reached on is forgotten, since the
    /// addresses may have changed.
    @discardableResult
    public func save(
        _ server: ValidServer,
        replacing existing: ServerProfile?
    ) async throws(AccountError) -> ServerProfile {
        let profile = try await accounts.save(server, replacing: existing)
        environment.defaults.removeObject(forKey: Self.addressKeyPrefix + profile.id)
        await reloadServers()
        if phase == .signedOut || isInUse(profile.id) {
            await connect(to: profile)
        }
        return profile
    }

    /// Deletes a server with its stored data and Keychain secrets, signing out if it was in use.
    public func delete(_ profile: ServerProfile) async throws(AccountError) {
        if isInUse(profile.id) {
            await signOut()
        }
        try await accounts.delete(profile)
        DownloadManager.removeFiles(forServer: profile.id, in: environment.downloadsDirectory)
        environment.defaults.removeObject(forKey: Self.addressKeyPrefix + profile.id)
        await reloadServers()
    }

    /// Back to the server list. The server stays saved; the next launch shows the list.
    public func signOut() async {
        connection += 1
        stopReconnecting()
        await endSession()
        environment.defaults.removeObject(forKey: Self.lastServerKey)
        phase = .signedOut
    }

    /// Saves the player's place before the app quits.
    public func prepareForTermination() async {
        await session?.player.savePosition()
        session?.listening.saveNow()
        await session?.listening.settled()
    }

    /// The settings shared by every server.
    public var settings: AppSettings {
        environment.settings
    }

    /// Network conditions changed: downloads held for a better network may start, and an offline
    /// session gets a fresh round of retries, since the new network may reach the server.
    public func networkChanged() {
        session?.downloads.pump()
        if session?.isOffline == true {
            startReconnecting()
        }
    }

    /// Signed in to it, or connecting to it.
    private func isInUse(_ id: ServerProfile.ID) -> Bool {
        if case let .connecting(profile) = phase, profile.id == id {
            return true
        }
        return session?.profile.id == id
    }

    private func reloadServers() async {
        do {
            servers = try await accounts.all()
        } catch {
            errorMessage = error.userMessage
        }
    }

    // MARK: Connecting

    /// Signs in to `profile`: picks the address that answers (local or public), checks the account,
    /// and starts a session. An unreachable server still opens, offline, so cached data shows.
    public func connect(to profile: ServerProfile) async {
        connection += 1
        let attempt = connection
        stopReconnecting()
        errorMessage = nil
        phase = .connecting(profile)
        await endSession()

        let credentials: ServerCredentials
        do {
            credentials = try await accounts.credentials(for: profile)
        } catch {
            return fail(error.userMessage, attempt: attempt)
        }
        let reached = await reach(credentials)
        guard attempt == connection else { return }
        switch reached {
        case let .refused(error):
            fail(error.userMessage, attempt: attempt)
        case let .online(client, info):
            await startSession(profile: profile, client: client, info: info, attempt: attempt)
        case let .offline(client):
            await startSession(profile: profile, client: client, info: nil, attempt: attempt)
        }
    }

    enum Reachability {
        case online(SubsonicClient, ServerInfo)
        case offline(SubsonicClient)
        case refused(SubsonicError)
    }

    func reach(_ credentials: ServerCredentials) async -> Reachability {
        let profile = credentials.profile
        let tester = environment.tester
        let addressKey = Self.addressKeyPrefix + profile.id
        // Only ever the profile's own local address: a remembered address the profile no longer
        // has must not receive its credentials.
        let saved = environment.defaults.string(forKey: addressKey)
            .flatMap { try? ServerAddress($0) }
            .flatMap { $0 == profile.localAddress ? $0 : nil }
        let switcher = AddressSwitcher(
            publicAddress: profile.address,
            localAddress: profile.localAddress,
            inUse: saved,
            isReachable: { address in
                do throws(SubsonicError) {
                    _ = try await tester.ping(credentials.client(at: address))
                    return true
                } catch {
                    // Any device can answer 401 on a local address, so only a Subsonic answer moves
                    // credentials there. The public address may be behind a proxy that refuses.
                    return address == profile.address ? error.isAnswerFromServer : error.isSubsonicAnswer
                }
            }
        )
        guard let address = await switcher.refresh() else {
            return .offline(credentials.client(at: saved ?? profile.address))
        }
        environment.defaults.set(address.url.absoluteString, forKey: addressKey)
        let client = credentials.client(at: address)
        do throws(SubsonicError) {
            return try await .online(client, tester.ping(client))
        } catch {
            return error.isAnswerFromServer ? .refused(error) : .offline(client)
        }
    }

    private func startSession(profile: ServerProfile, client: SubsonicClient, info: ServerInfo?, attempt: Int) async {
        let saved = await savedQueue(server: profile.id)
        // Nothing below awaits, so no other connect can interleave once this check passes.
        guard attempt == connection else { return }
        install(profile: profile, client: client, info: info, saved: saved)
    }

    func savedQueue(server: ServerProfile.ID) async -> SavedQueue? {
        do {
            return try await QueueStore(database: environment.database).load(server: server)
        } catch {
            Self.logger.error("Couldn't restore the play queue: \(error)")
            return nil
        }
    }

    /// Hands the engine to a new session for `client` and makes it the one in use. Doesn't await.
    func install(profile: ServerProfile, client: SubsonicClient, info: ServerInfo?, saved: SavedQueue?) {
        engine.setPolicy(client.mediaRequestPolicy)
        let session = makeSession(profile: profile, client: client, info: info, saved: saved)
        self.session = session
        session.start()
        nowPlaying?.attach(to: session.player)
        observeCurrentSong(of: session)
        environment.defaults.set(profile.id, forKey: Self.lastServerKey)
        phase = .signedIn
        // A round a network change started while the old session ended was for that session.
        stopReconnecting()
        if session.isOffline {
            startReconnecting()
        }
    }

    /// Pauses the player where it is, saves its place and takes the engine back. The session is
    /// cleared before the save is awaited, so a connect that starts meanwhile can't end it twice,
    /// and the engine is only reset if no newer session has taken it since.
    private func endSession() async {
        guard let ending = session else { return }
        session = nil
        detachNowPlaying()
        ending.player.pause()
        await ending.player.savePosition()
        await ending.end()
        if session == nil {
            engine.setPolicy(nil)
        }
    }

    private func fail(_ message: String, attempt: Int) {
        guard attempt == connection else { return }
        errorMessage = message
        phase = .signedOut
    }

    func detachNowPlaying() {
        artworkTask?.cancel()
        artworkSongID = nil
        nowPlaying?.detach()
    }

    // MARK: Now Playing artwork

    /// Loads the cover for the system's Now Playing whenever the current song changes. The
    /// observation holds the session weakly, so an ended session is released.
    private func observeCurrentSong(of session: ServerSession) {
        guard self.session === session else { return }
        let song = withObservationTracking {
            session.player.queue.current?.song
        } onChange: { [weak self, weak session] in
            Task { @MainActor in
                guard let self, let session else { return }
                self.observeCurrentSong(of: session)
            }
        }
        guard let nowPlaying, song?.id != artworkSongID else { return }
        artworkSongID = song?.id
        artworkTask?.cancel()
        guard let song else { return }
        artworkTask = Task { [weak session] in
            let image = await session?.artwork.image(coverArtID: song.coverArtID, size: .large)
            guard !Task.isCancelled else { return }
            nowPlaying.setArtwork(image, forSongID: song.id)
        }
    }
}

private extension AppModel {
    /// A session for `client`, with its player restored to `saved`, not yet started.
    func makeSession(
        profile: ServerProfile,
        client: SubsonicClient,
        info: ServerInfo?,
        saved: SavedQueue?
    ) -> ServerSession {
        let downloads = DownloadManager(
            client: client,
            database: environment.database,
            serverID: profile.id,
            directory: environment.downloadsDirectory,
            downloader: environment.downloader,
            settings: environment.settings,
            streamSettings: { [weak self] in self?.session?.player.settings.stream ?? StreamSettings() },
            isOnConstrainedNetwork: environment.isOnConstrainedNetwork,
            now: { Date() }
        )
        let player = PlayerController(
            engine: engine,
            source: SessionStreamSource(remote: SubsonicStreamSource(client: client), downloads: downloads.index),
            queueSaver: QueueStore(database: environment.database),
            serverID: profile.id,
            settingsStore: environment.settingsStore,
            environment: PlayerEnvironment(
                now: { Date() },
                sleep: PlayerEnvironment.live.sleep,
                isOnConstrainedNetwork: environment.isOnConstrainedNetwork
            )
        )
        if let saved {
            player.restore(saved)
        }
        return ServerSession(
            profile: profile, client: client, serverInfo: info, player: player, downloads: downloads,
            database: environment.database, artworkCaches: environment.artworkCaches, settings: environment.settings
        )
    }
}

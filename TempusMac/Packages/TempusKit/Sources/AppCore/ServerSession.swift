import Foundation
import Library
import Observation
import Persistence
import Playback
import SubsonicAPI

/// An engine that can be handed from one server to another. `StreamingEngine` stops playback
/// before switching, so no request for the old server is judged by the new server's rules.
@MainActor
public protocol PolicySwitchingEngine: PlayerEngine {
    func setPolicy(_ policy: MediaRequestPolicy?)
}

extension StreamingEngine: PolicySwitchingEngine {}

/// Everything tied to the server in use: its client for the address that answered, the player,
/// covers, lyrics, the cache-first library, stars, downloads and the listening sync. Replaced as a
/// whole when the server changes.
@MainActor
@Observable
public final class ServerSession {
    public let profile: ServerProfile
    public let client: SubsonicClient
    /// Nil when the server couldn't be reached at sign-in.
    public let serverInfo: ServerInfo?
    /// The server didn't answer at sign-in: screens show cached data and an offline notice.
    public let isOffline: Bool
    public let player: PlayerController
    public let artwork: ArtworkPipeline
    public let library: CachedLibrary
    public let lyrics: LyricsService
    public let settings: AppSettings
    public let stars: StarService
    public let downloads: DownloadManager
    public let features: ServerFeatures
    public let listening: ListeningSync
    public let playlists: PlaylistService
    public let radio: RadioService
    public let sources: PlaybackSources
    public let history: HistoryStore
    public let recentSearches: RecentSearchStore

    @ObservationIgnored private let scrobbler: Scrobbler
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    init(
        profile: ServerProfile,
        client: SubsonicClient,
        serverInfo: ServerInfo?,
        player: PlayerController,
        downloads: DownloadManager,
        database: AppDatabase,
        artworkCaches: ArtworkCaches,
        settings: AppSettings,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.profile = profile
        self.client = client
        self.serverInfo = serverInfo
        isOffline = serverInfo == nil
        self.player = player
        self.downloads = downloads
        self.settings = settings
        artwork = ArtworkPipeline(client: client, serverID: profile.id, caches: artworkCaches)
        library = CachedLibrary(client: client, cache: ResponseCache(database: database), serverID: profile.id)
        lyrics = LyricsService(
            client: client,
            store: LyricsStore(database: database),
            serverID: profile.id,
            // Unknown while offline: try the OpenSubsonic call and fall back.
            supportsSongLyrics: serverInfo?.isOpenSubsonic ?? true
        )
        stars = StarService(
            client: client,
            pending: PendingStarStore(database: database),
            serverID: profile.id,
            now: now
        )
        features = ServerFeatures(client: client)
        listening = ListeningSync(player: player, client: client, settings: settings, now: now)
        playlists = PlaylistService(client: client, pins: PinnedPlaylistStore(database: database), serverID: profile.id)
        radio = RadioService(client: client, local: LocalRadioStore(database: database))
        sources = PlaybackSources(client: client)
        history = HistoryStore(database: database)
        recentSearches = RecentSearchStore(database: database)
        scrobbler = Scrobbler(client: client, history: history, serverID: profile.id, settings: settings)
    }

    /// Starts the session's background work: scrobbling, the listening sync, and, when the
    /// server answered, sending queued stars, probing features and syncing downloads.
    func start() {
        let events = player.events
        tasks.append(Task { [scrobbler] in await scrobbler.run(events: events) })
        listening.start()
        // The parts, not the session, so an ended session is released while these finish.
        tasks.append(Task { [downloads, stars, features, isOffline] in
            await downloads.load()
            guard !isOffline else { return }
            await stars.sendPending()
            await features.probe()
            await downloads.syncAll()
        })
    }

    /// Stops the background work and waits for the last position saves to go out.
    func end() async {
        listening.stop()
        downloads.end()
        for task in tasks {
            task.cancel()
        }
        tasks = []
        await listening.settled()
    }

    /// The music folder browsing and search are limited to, or nil for all libraries.
    public var musicFolderID: String? {
        settings.musicFolderID(server: profile.id)
    }
}

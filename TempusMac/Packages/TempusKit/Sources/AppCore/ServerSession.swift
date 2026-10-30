import Foundation
import Library
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
/// covers, lyrics and the cache-first library. Replaced as a whole when the server changes.
@MainActor
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

    init(
        profile: ServerProfile,
        client: SubsonicClient,
        serverInfo: ServerInfo?,
        player: PlayerController,
        database: AppDatabase,
        artworkCaches: ArtworkCaches
    ) {
        self.profile = profile
        self.client = client
        self.serverInfo = serverInfo
        isOffline = serverInfo == nil
        self.player = player
        artwork = ArtworkPipeline(client: client, serverID: profile.id, caches: artworkCaches)
        library = CachedLibrary(client: client, cache: ResponseCache(database: database), serverID: profile.id)
        lyrics = LyricsService(
            client: client,
            store: LyricsStore(database: database),
            serverID: profile.id,
            // Unknown while offline: try the OpenSubsonic call and fall back.
            supportsSongLyrics: serverInfo?.isOpenSubsonic ?? true
        )
    }
}

import Foundation
import Observation
import os

/// Settings outside playback (which `PlaybackSettingsStore` keeps): scrobbling, queue sync, the
/// library in use, Home's and the sidebar's layout, sorting, downloads, the update channel, the theme,
/// Discord and lyrics search. Kept in UserDefaults; nothing here is secret.
@MainActor
@Observable
public final class AppSettings {
    static let prefix = "settings."
    private static let logger = Logger(subsystem: "io.github.unrefundable.TempusMac", category: "Settings")

    @ObservationIgnored private let defaults: UserDefaults

    /// Upstream's "Enable music scrobbling", on by default.
    public var scrobbles: Bool {
        didSet { defaults.set(scrobbles, forKey: Self.prefix + "scrobbles") }
    }

    /// Upstream's "Sync play queue for this user", off by default.
    public var syncsPlayQueue: Bool {
        didSet { defaults.set(syncsPlayQueue, forKey: Self.prefix + "syncsPlayQueue") }
    }

    /// Keeps the spot of podcasts, audiobooks and long tracks as server bookmarks.
    public var savesBookmarks: Bool {
        didSet { defaults.set(savesBookmarks, forKey: Self.prefix + "savesBookmarks") }
    }

    /// Upstream's "Show track number" in the player and lists.
    public var showsTrackNumber: Bool {
        didSet { defaults.set(showsTrackNumber, forKey: Self.prefix + "showsTrackNumber") }
    }

    /// Home's sections in order; hidden ones are left out.
    public private(set) var homeLayout: HomeLayout {
        didSet { defaults.set(homeLayout.visible.map(\.rawValue), forKey: Self.prefix + "homeSections") }
    }

    /// The sidebar's items in order, and which are hidden.
    public private(set) var sidebarLayout: SidebarLayout {
        didSet {
            defaults.set(sidebarLayout.order.map(\.rawValue), forKey: Self.prefix + "sidebarOrder")
            defaults.set(sidebarLayout.hidden.map(\.rawValue).sorted(), forKey: Self.prefix + "sidebarHidden")
        }
    }

    public var playlistSort: PlaylistSort {
        didSet { defaults.set(playlistSort.rawValue, forKey: Self.prefix + "playlistSort") }
    }

    public var albumSort: AlbumSort {
        didSet { defaults.set(albumSort.rawValue, forKey: Self.prefix + "albumSort") }
    }

    public var downloadGrouping: DownloadGrouping {
        didSet { defaults.set(downloadGrouping.rawValue, forKey: Self.prefix + "downloadGrouping") }
    }

    /// Upstream's "Download only on Wi-Fi": here, not on a hotspot or in Low Data Mode.
    public var downloadsOnlyUnconstrained: Bool {
        didSet { defaults.set(downloadsOnlyUnconstrained, forKey: Self.prefix + "downloadsOnlyUnconstrained") }
    }

    /// Downloads use the stream quality settings instead of the original file.
    public var transcodesDownloads: Bool {
        didSet { defaults.set(transcodesDownloads, forKey: Self.prefix + "transcodesDownloads") }
    }

    /// Keeps starred tracks downloaded (upstream's "Sync starred tracks for offline use").
    public var syncsStarredTracks: Bool {
        didSet { defaults.set(syncsStarredTracks, forKey: Self.prefix + "syncsStarredTracks") }
    }

    /// Offers pre-releases as updates too. Sparkle keeps the other update settings itself.
    public var receivesBetaUpdates: Bool {
        didSet { defaults.set(receivesBetaUpdates, forKey: Self.prefix + "receivesBetaUpdates") }
    }

    /// The app's look: a preset, light or dark, and any custom colors.
    public private(set) var theme: AppTheme {
        didSet { storeTheme() }
    }

    /// Shows the track playing in the user's Discord status. Off by default, since it tells
    /// everyone who can see the user on Discord what they listen to.
    public var sharesNowPlayingOnDiscord: Bool {
        didSet { defaults.set(sharesNowPlayingOnDiscord, forKey: Self.prefix + "sharesNowPlayingOnDiscord") }
    }

    /// Lets search find songs by their lyrics. Off by default: on, Tempus fetches every song's
    /// lyrics from the server once and keeps them up to date (see `LyricsSearch`).
    public var searchesLyrics: Bool {
        didSet { defaults.set(searchesLyrics, forKey: Self.prefix + "searchesLyrics") }
    }

    /// - Parameter isPrereleaseBuild: whether the app running is a beta, which makes beta updates
    ///   the default, so a beta tester keeps getting betas.
    public init(defaults: UserDefaults = .standard, isPrereleaseBuild: Bool = UpdateChannel.isRunningPrerelease) {
        self.defaults = defaults
        let bool = { (key: String, fallback: Bool) in
            defaults.object(forKey: Self.prefix + key) as? Bool ?? fallback
        }
        scrobbles = bool("scrobbles", true)
        syncsPlayQueue = bool("syncsPlayQueue", false)
        savesBookmarks = bool("savesBookmarks", true)
        showsTrackNumber = bool("showsTrackNumber", false)
        downloadsOnlyUnconstrained = bool("downloadsOnlyUnconstrained", false)
        transcodesDownloads = bool("transcodesDownloads", false)
        syncsStarredTracks = bool("syncsStarredTracks", false)
        receivesBetaUpdates = bool("receivesBetaUpdates", isPrereleaseBuild)
        sharesNowPlayingOnDiscord = bool("sharesNowPlayingOnDiscord", false)
        searchesLyrics = bool("searchesLyrics", false)
        theme = Self.storedTheme(in: defaults)
        homeLayout = HomeLayout(stored: defaults.stringArray(forKey: Self.prefix + "homeSections"))
        sidebarLayout = SidebarLayout(
            storedOrder: defaults.stringArray(forKey: Self.prefix + "sidebarOrder"),
            storedHidden: defaults.stringArray(forKey: Self.prefix + "sidebarHidden")
        )
        playlistSort = defaults.string(forKey: Self.prefix + "playlistSort").flatMap(PlaylistSort.init) ?? .name
        albumSort = defaults.string(forKey: Self.prefix + "albumSort").flatMap(AlbumSort.init) ?? .name
        downloadGrouping = defaults.string(forKey: Self.prefix + "downloadGrouping")
            .flatMap(DownloadGrouping.init) ?? .track
    }

    public func setHomeLayout(_ layout: HomeLayout) {
        homeLayout = layout
    }

    public func setSidebarLayout(_ layout: SidebarLayout) {
        sidebarLayout = layout
    }

    public func setTheme(_ theme: AppTheme) {
        self.theme = theme
    }

    private static func storedTheme(in defaults: UserDefaults) -> AppTheme {
        guard let data = defaults.data(forKey: prefix + "theme") else { return .default }
        do {
            return try JSONDecoder().decode(AppTheme.self, from: data)
        } catch {
            logger.error("The saved theme couldn't be read, so the default is used: \(error)")
            return .default
        }
    }

    private func storeTheme() {
        do {
            try defaults.set(JSONEncoder().encode(theme), forKey: Self.prefix + "theme")
        } catch {
            Self.logger.error("Couldn't save the theme: \(error)")
        }
    }

    // MARK: Per server

    /// The music folder browsing and search are limited to, or nil for all libraries.
    public func musicFolderID(server: String) -> String? {
        _ = musicFolderRevision // observed, so a change reloads the screens that read it
        return defaults.string(forKey: Self.prefix + "musicFolder." + server)
    }

    public func setMusicFolderID(_ id: String?, server: String) {
        let key = Self.prefix + "musicFolder." + server
        if let id {
            defaults.set(id, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        musicFolderRevision += 1
    }

    /// Bumped when a library choice changes, so screens observing it reload.
    public private(set) var musicFolderRevision = 0

    /// How far either way one song's lyrics can be nudged, in seconds.
    public static let lyricsNudgeLimit: TimeInterval = 60
    /// One press of the lyrics panel's earlier or later button.
    public static let lyricsNudgeStep: TimeInterval = 0.5

    /// How many seconds sooner (later when negative) the user wants a song's synced lyrics, for
    /// lyrics whose times are out of step with this server's audio file. 0 when never nudged.
    public func lyricsNudge(song: String, server: String) -> TimeInterval {
        _ = lyricsNudgeRevision
        return defaults.double(forKey: Self.lyricsNudgeKey(song: song, server: server))
    }

    public func setLyricsNudge(_ seconds: TimeInterval, song: String, server: String) {
        let key = Self.lyricsNudgeKey(song: song, server: server)
        let clamped = min(max(seconds, -Self.lyricsNudgeLimit), Self.lyricsNudgeLimit)
        if clamped == 0 || !clamped.isFinite {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(clamped, forKey: key)
        }
        lyricsNudgeRevision += 1
    }

    /// Bumped when a lyrics nudge changes, so the lyrics panel observing it moves its lines.
    public private(set) var lyricsNudgeRevision = 0

    private static func lyricsNudgeKey(song: String, server: String) -> String {
        prefix + "lyricsNudge." + server + "." + song
    }
}

/// How the Albums screen sorts, mapped onto `getAlbumList2` types.
public enum AlbumSort: String, CaseIterable, Sendable, Identifiable {
    case name, artist, newest, recent, frequent, highest, random, starred

    public var id: Self {
        self
    }

    public var title: String {
        switch self {
        case .name: "Name"
        case .artist: "Artist"
        case .newest: "Recently Added"
        case .recent: "Recently Played"
        case .frequent: "Most Played"
        case .highest: "Top Rated"
        case .random: "Random"
        case .starred: "Starred"
        }
    }
}

/// How the Downloads view groups tracks, as upstream's filter button.
public enum DownloadGrouping: String, CaseIterable, Sendable, Identifiable {
    case track, album, artist, genre, playlist, year

    public var id: Self {
        self
    }

    public var title: String {
        rawValue.capitalized
    }
}

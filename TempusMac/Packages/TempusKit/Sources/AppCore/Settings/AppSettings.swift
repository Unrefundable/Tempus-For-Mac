import Foundation
import Observation

/// Settings outside playback (which `PlaybackSettingsStore` keeps): scrobbling, queue sync, the
/// library in use, Home's and the sidebar's layout, sorting and downloads. Kept in UserDefaults;
/// nothing here is secret.
@MainActor
@Observable
public final class AppSettings {
    static let prefix = "settings."

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

    public init(defaults: UserDefaults = .standard) {
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

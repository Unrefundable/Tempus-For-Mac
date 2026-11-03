import Foundation
import SubsonicAPI

/// Home's sections, after upstream's Music tab. Each one is a row of covers or tracks.
public enum HomeSection: String, CaseIterable, Sendable, Identifiable, Codable {
    case continueListening
    case discover
    case recentlyPlayed
    case recentlyAdded
    case mostPlayed
    case recentAlbums
    case topRated
    case starredTracks
    case starredAlbums
    case starredArtists
    case thisWeek
    case flashback
    case randomAlbums
    case pinnedPlaylists
    case playlists
    case genres
    case newestPodcasts

    public var id: Self {
        self
    }

    public var title: String {
        switch self {
        case .continueListening: "Continue Listening"
        case .discover: "Discover"
        case .recentlyPlayed: "Recently Played"
        case .recentlyAdded: "Recently Added"
        case .mostPlayed: "Most Played Albums"
        case .recentAlbums: "Recently Played Albums"
        case .topRated: "Top Rated"
        case .starredTracks: "Starred Tracks"
        case .starredAlbums: "Starred Albums"
        case .starredArtists: "Starred Artists"
        case .thisWeek: "Your Week"
        case .flashback: "Flashback"
        case .randomAlbums: "Random Albums"
        case .pinnedPlaylists: "Pinned Playlists"
        case .playlists: "Playlists"
        case .genres: "Genres"
        case .newestPodcasts: "New Podcast Episodes"
        }
    }

    /// Upstream shows most sections by default; the rest can be turned on in Settings.
    static let defaultOrder: [Self] = [
        .continueListening, .discover, .recentlyPlayed, .recentlyAdded, .starredTracks, .starredAlbums,
        .starredArtists, .pinnedPlaylists, .mostPlayed, .recentAlbums, .thisWeek, .flashback, .playlists,
        .newestPodcasts,
    ]
}

/// The visible sections in order. Hidden ones are the rest of `HomeSection.allCases`.
public struct HomeLayout: Sendable, Equatable {
    public let visible: [HomeSection]

    public init(visible: [HomeSection]) {
        var seen = Set<HomeSection>()
        self.visible = visible.filter { seen.insert($0).inserted }
    }

    /// Unknown names from an older or newer version are ignored.
    init(stored: [String]?) {
        guard let stored else {
            self.init(visible: HomeSection.defaultOrder)
            return
        }
        self.init(visible: stored.compactMap(HomeSection.init(rawValue:)))
    }

    public static let `default` = HomeLayout(visible: HomeSection.defaultOrder)

    public var hidden: [HomeSection] {
        HomeSection.allCases.filter { !visible.contains($0) }
    }

    public func showing(_ section: HomeSection) -> Self {
        visible.contains(section) ? self : Self(visible: visible + [section])
    }

    public func hiding(_ section: HomeSection) -> Self {
        Self(visible: visible.filter { $0 != section })
    }

    /// Moves the sections at `offsets` to before `destination`, as `onMove` reports.
    public func moving(fromOffsets offsets: IndexSet, toOffset destination: Int) -> Self {
        let moved = offsets.sorted().map { visible[$0] }
        var rest = visible.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let insertAt = destination - offsets.count(in: 0 ..< destination)
        rest.insert(contentsOf: moved, at: max(0, min(insertAt, rest.count)))
        return Self(visible: rest)
    }
}

/// Upstream's playlist sort options (Settings → Playlist → Playlist sorting).
public enum PlaylistSort: String, CaseIterable, Sendable, Identifiable {
    case name, random, dateCreated, songCount, faves, lastUpdated

    public var id: Self {
        self
    }

    public var title: String {
        switch self {
        case .name: "Name"
        case .random: "Random"
        case .dateCreated: "Date Created"
        case .songCount: "Song Count"
        case .faves: "Faves"
        case .lastUpdated: "Last Updated"
        }
    }

    /// Sorts `playlists`; `faves` are the pinned ids, which go first for `.faves`. Ties fall back to
    /// name, so the order is stable.
    public func sorted(
        _ playlists: [Playlist],
        faves: Set<String> = [],
        using generator: inout some RandomNumberGenerator
    ) -> [Playlist] {
        let byName = playlists.sorted { Self.name($0).localizedStandardCompare(Self.name($1)) == .orderedAscending }
        switch self {
        case .name:
            return byName
        case .random:
            return byName.shuffled(using: &generator)
        case .dateCreated:
            return byName.stableSorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
        case .songCount:
            return byName.stableSorted { ($0.songCount ?? 0) > ($1.songCount ?? 0) }
        case .faves:
            return byName.stableSorted { faves.contains($0.id) && !faves.contains($1.id) }
        case .lastUpdated:
            return byName.stableSorted { ($0.changed ?? .distantPast) > ($1.changed ?? .distantPast) }
        }
    }

    public func sorted(_ playlists: [Playlist], faves: Set<String> = []) -> [Playlist] {
        var generator = SystemRandomNumberGenerator()
        return sorted(playlists, faves: faves, using: &generator)
    }

    private static func name(_ playlist: Playlist) -> String {
        playlist.name ?? ""
    }
}

public extension AlbumSort {
    /// The `getAlbumList2` type behind each sort.
    var listType: AlbumListType {
        switch self {
        case .name: .alphabeticalByName
        case .artist: .alphabeticalByArtist
        case .newest: .newest
        case .recent: .recent
        case .frequent: .frequent
        case .highest: .highest
        case .random: .random
        case .starred: .starred
        }
    }
}

extension Array {
    /// Sorted by `areInIncreasingOrder`, keeping the existing order of equal elements.
    func stableSorted(by areInIncreasingOrder: (Element, Element) -> Bool) -> [Element] {
        enumerated().sorted { lhs, rhs in
            if areInIncreasingOrder(lhs.element, rhs.element) {
                return true
            }
            if areInIncreasingOrder(rhs.element, lhs.element) {
                return false
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}

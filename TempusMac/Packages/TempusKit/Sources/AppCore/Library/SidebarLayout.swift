import Foundation

/// The sidebar's groups. Items stay in their own group; only the order within one can change.
public enum SidebarSection: String, CaseIterable, Sendable, Identifiable {
    case main, library, more

    public var id: Self {
        self
    }

    /// The header the sidebar shows, or nil for the untitled group at the top.
    public var title: String? {
        switch self {
        case .main: nil
        case .library: "Library"
        case .more: "More"
        }
    }

    /// For lists that name every group, such as the sidebar editor.
    public var editorTitle: String {
        title ?? "General"
    }
}

/// Where the sidebar can go.
public enum SidebarItem: String, CaseIterable, Sendable, Identifiable, Codable {
    case nowPlaying, home, search
    case albums, artists, genres, playlists, favorites, folders
    case podcasts, radio, shares, downloads

    public var id: Self {
        self
    }

    public var title: String {
        switch self {
        case .nowPlaying: "Now Playing"
        case .home: "Home"
        case .search: "Search"
        case .albums: "Albums"
        case .artists: "Artists"
        case .genres: "Genres"
        case .playlists: "Playlists"
        case .favorites: "Favorites"
        case .folders: "Music Folders"
        case .podcasts: "Podcasts"
        case .radio: "Radio"
        case .shares: "Shares"
        case .downloads: "Downloads"
        }
    }

    public var section: SidebarSection {
        switch self {
        case .nowPlaying, .home, .search: .main
        case .albums, .artists, .genres, .playlists, .favorites, .folders: .library
        case .podcasts, .radio, .shares, .downloads: .more
        }
    }
}

/// Which sidebar items show and in what order, like Finder's and Music's Edit Sidebar. `order`
/// always holds every item, so a hidden item comes back where it was; the sidebar groups it by
/// `section`.
public struct SidebarLayout: Sendable, Equatable {
    public let order: [SidebarItem]
    public let hidden: Set<SidebarItem>

    /// Repeats are dropped, and items `order` leaves out follow it in their default order, so ones
    /// added in a later version show up.
    public init(order: [SidebarItem], hidden: Set<SidebarItem> = []) {
        var seen = Set<SidebarItem>()
        let known = order.filter { seen.insert($0).inserted }
        self.order = known + SidebarItem.allCases.filter { !seen.contains($0) }
        self.hidden = hidden
    }

    /// Unknown names from an older or newer version are ignored.
    init(storedOrder: [String]?, storedHidden: [String]?) {
        self.init(
            order: (storedOrder ?? []).compactMap(SidebarItem.init(rawValue:)),
            hidden: Set((storedHidden ?? []).compactMap(SidebarItem.init(rawValue:)))
        )
    }

    public static let `default` = SidebarLayout(order: SidebarItem.allCases)

    /// Every item in `section`, hidden ones included, in order.
    public func items(in section: SidebarSection) -> [SidebarItem] {
        order.filter { $0.section == section }
    }

    public func visibleItems(in section: SidebarSection) -> [SidebarItem] {
        items(in: section).filter(isVisible)
    }

    public func isVisible(_ item: SidebarItem) -> Bool {
        !hidden.contains(item)
    }

    /// The last visible item stays, so the sidebar is never empty.
    public func canHide(_ item: SidebarItem) -> Bool {
        isVisible(item) && order.contains { $0 != item && isVisible($0) }
    }

    public func showing(_ item: SidebarItem) -> Self {
        Self(order: order, hidden: hidden.subtracting([item]))
    }

    public func hiding(_ item: SidebarItem) -> Self {
        Self(order: order, hidden: hidden.union([item]))
    }

    public func setting(_ item: SidebarItem, visible: Bool) -> Self {
        visible ? showing(item) : hiding(item)
    }

    /// Moves the rows at `offsets` of `rows` to before `destination`, as `onMove` reports for a
    /// list showing `rows` (a section, perhaps without its hidden items). Items that aren't in
    /// `rows` keep their places.
    public func moving(fromOffsets offsets: IndexSet, toOffset destination: Int, among rows: [SidebarItem]) -> Self {
        let valid = offsets.filter { rows.indices.contains($0) }
        let moved = valid.sorted().map { rows[$0] }
        var rest = rows.enumerated().filter { !valid.contains($0.offset) }.map(\.element)
        let insertAt = destination - valid.count { $0 < destination }
        rest.insert(contentsOf: moved, at: max(0, min(insertAt, rest.count)))
        // The rows' slots in `order`, refilled in their new order.
        let slots = Set(rows)
        var reordered = rest.makeIterator()
        return Self(order: order.map { slots.contains($0) ? reordered.next() ?? $0 : $0 }, hidden: hidden)
    }
}

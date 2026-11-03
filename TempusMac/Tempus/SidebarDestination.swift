import DesignSystem
import SwiftUI

/// The sidebar's places, in the order of upstream's navigation drawer (`menu/nav_drawer.xml`).
enum SidebarDestination: String, CaseIterable, Identifiable, Hashable {
    case home
    case library
    case downloads
    case albums
    case artists
    case genres
    case playlists

    static let main: [Self] = [.home, .library, .downloads]
    static let catalogues: [Self] = [.albums, .artists, .genres, .playlists]

    var id: Self {
        self
    }

    var title: LocalizedStringKey {
        switch self {
        case .home: "Home"
        case .library: "Library"
        case .downloads: "Downloads"
        case .albums: "Albums"
        case .artists: "Artists"
        case .genres: "Genres"
        case .playlists: "Playlists"
        }
    }

    var icon: TempusIcon {
        switch self {
        case .home: .home
        case .library: .graphicEq
        case .downloads: .playForWork
        case .albums: .albums
        case .artists: .artists
        case .genres: .genres
        case .playlists: .playlist
        }
    }

    /// What the page shows before there is anything to list, with upstream's wording where it has one.
    var emptyState: EmptyState {
        switch self {
        case .downloads:
            EmptyState(
                illustration: .emptyList,
                title: "No downloads yet!",
                subtitle: "Once you download a song, you'll find it here"
            )
        default:
            EmptyState(
                illustration: .emptyResponse,
                title: "No server added",
                subtitle: "Connect to a Subsonic server to get started."
            )
        }
    }
}

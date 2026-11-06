import AppCore
import DesignSystem
import Library
import Persistence
import SubsonicAPI
import SwiftUI

/// Where a click inside the library leads.
enum Route: Hashable {
    case album(id: String)
    case artist(id: String)
    case playlist(id: String)
    case genre(String)
    case folder(id: String, name: String)
    case podcast(id: String)
    case allPlaylists
}

/// The sidebar's selection and each screen's navigation path, shared with the menu commands.
@MainActor
@Observable
final class Navigator {
    var selection: SidebarItem = .home {
        didSet {
            if oldValue != selection {
                path = []
            }
        }
    }

    var path: [Route] = []
    /// Bumped by ⌘F so the search field takes focus.
    var searchFocusRequest = 0
    /// Shows the Edit Sidebar sheet, from View › Edit Sidebar… or the sidebar's context menu.
    var isEditingSidebar = false

    func open(_ route: Route) {
        if selection == .nowPlaying {
            selection = .home
        }
        path.append(route)
    }

    func search() {
        selection = .search
        searchFocusRequest += 1
    }
}

/// The screen a `Route` opens. Navigation is the `Navigator`'s path drawn by hand rather than a
/// `NavigationStack`: inside `NavigationSplitView`, a pushed destination replaced the whole detail
/// column, taking the player bar and the lyrics/queue panel with it.
struct RouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case let .album(id): AlbumDetailView(albumID: id)
        case let .artist(id): ArtistDetailView(artistID: id)
        case let .playlist(id): PlaylistDetailView(playlistID: id)
        case let .genre(name): GenreDetailView(genre: name)
        case let .folder(id, name): FolderDetailView(folderID: id, name: name)
        case let .podcast(id): PodcastChannelView(channelID: id)
        case .allPlaylists: PlaylistsView()
        }
    }
}

/// Shows a library request cache-first: the saved answer at once, then the server's. Keeps the
/// last value when the server can't be reached, with a quiet notice instead of an error.
struct SnapshotView<Value: Decodable & Sendable, Content: View>: View {
    let request: SubsonicRequest<Value>
    /// Changes reload the request (a new sort, a new library).
    var reloadKey: AnyHashable = 0
    @ViewBuilder let content: (Value) -> Content

    @Environment(ServerSession.self) private var session
    @State private var value: Value?
    @State private var errorMessage: String?
    @State private var isStale = false
    @State private var attempt = 0

    var body: some View {
        Group {
            if let value {
                content(value)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if isStale, let errorMessage {
                            Label(errorMessage, systemImage: "icloud.slash")
                                .font(.inter(.caption))
                                .foregroundStyle(Theme.secondaryText)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, Theme.Spacing.xSmall)
                                .background(.bar)
                        }
                    }
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Couldn't load", tempus: .error).tempusIconKeepsForeground()
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { attempt += 1 }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: [reloadKey, AnyHashable(attempt), AnyHashable(request.cacheKey)]) {
            await load()
        }
    }

    private func load() async {
        errorMessage = nil
        do {
            for try await snapshot in session.library.snapshots(request) {
                value = snapshot.value
                if case .server = snapshot.source {
                    isStale = false
                } else {
                    isStale = true
                }
            }
        } catch is CancellationError {
            return
        } catch let error as SubsonicError {
            errorMessage = error == .cancelled ? nil : error.userMessage
        } catch {
            errorMessage = "Something went wrong."
        }
    }
}

// MARK: Tiles

/// A cover with two lines under it, for albums, playlists and podcasts.
struct CoverTile: View {
    let coverArtID: String?
    let title: String
    let subtitle: String?
    var size: CGFloat = Theme.Size.tile
    var placeholder: TempusPlaceholder = .album

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            ArtworkView(coverArtID: coverArtID, size: .medium, placeholder: placeholder)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            Text(title)
                .font(.inter(.callout, weight: .medium))
                .lineLimit(1)
            Text(subtitle ?? " ")
                .font(.inter(.caption))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
        }
        .frame(width: size, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

struct AlbumTile: View {
    let album: Album
    var size: CGFloat = Theme.Size.tile

    @Environment(Navigator.self) private var navigator

    var body: some View {
        Button {
            navigator.open(.album(id: album.id))
        } label: {
            CoverTile(
                coverArtID: album.coverArtID,
                title: album.name ?? "Untitled",
                subtitle: album.displayArtist ?? album.artist,
                size: size
            )
        }
        .buttonStyle(.tempusPlain)
        .contextMenu { AlbumMenu(album: album) }
    }
}

struct ArtistTile: View {
    let artist: Artist
    var size: CGFloat = Theme.Size.tile

    @Environment(Navigator.self) private var navigator

    var body: some View {
        Button {
            navigator.open(.artist(id: artist.id))
        } label: {
            VStack(spacing: Theme.Spacing.xSmall) {
                ArtworkView(coverArtID: artist.coverArtID, size: .medium, cornerRadius: size / 2, placeholder: .artist)
                    .frame(width: size, height: size)
                Text(artist.name ?? "Unknown artist")
                    .font(.inter(.callout, weight: .medium))
                    .lineLimit(1)
                Text(artist.albumCount.map { "\($0) albums" } ?? " ")
                    .font(.inter(.caption))
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(width: size)
            .contentShape(.rect)
        }
        .buttonStyle(.tempusPlain)
        .contextMenu { ArtistMenu(artist: artist) }
    }
}

/// Upstream's horizontal carousel: a titled row of tiles, with an optional See All.
struct CoverRow<Item: Identifiable, Tile: View>: View {
    let title: String
    let items: [Item]
    var seeAll: (() -> Void)?
    @ViewBuilder let tile: (Item) -> Tile

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack {
                Text(title).font(.inter(.title2, weight: .bold))
                Spacer()
                if let seeAll {
                    Button("See All", action: seeAll).buttonStyle(.link)
                }
            }
            .padding(.horizontal, Theme.Spacing.xLarge)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Theme.Spacing.large) {
                    ForEach(items) { tile($0) }
                }
                .padding(.horizontal, Theme.Spacing.xLarge)
            }
            .scrollIndicators(.never)
        }
    }
}

/// An adaptive grid of album tiles.
struct AlbumGrid: View {
    let albums: [Album]
    var onReachEnd: (() -> Void)?

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: Theme.Size.tile), spacing: Theme.Spacing.large)],
            spacing: Theme.Spacing.xLarge
        ) {
            ForEach(albums) { album in
                AlbumTile(album: album)
                    .onAppear {
                        if album.id == albums.last?.id {
                            onReachEnd?()
                        }
                    }
            }
        }
        .padding(Theme.Spacing.xLarge)
    }
}

/// A big header with cover, titles and play/shuffle buttons, for album, playlist and artist pages.
struct DetailHeader<Actions: View>: View {
    let coverArtID: String?
    let kind: String
    let title: String
    let subtitle: String?
    let detail: String?
    var round = false
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.xLarge) {
            ArtworkView(
                coverArtID: coverArtID,
                size: .large,
                cornerRadius: round ? Theme.Size.detailCover / 2 : Theme.Radius.artwork,
                placeholder: round ? .artist : .album
            )
            .frame(width: Theme.Size.detailCover, height: Theme.Size.detailCover)
            .shadow(radius: 8, y: 4)
            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                Text(kind.uppercased()).font(.inter(.caption, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                Text(title).font(.inter(.largeTitle, weight: .bold)).lineLimit(2).textSelection(.enabled)
                if let subtitle {
                    Text(subtitle).font(.inter(.title3)).foregroundStyle(Theme.secondaryText)
                }
                if let detail {
                    Text(detail).font(.inter(.callout)).foregroundStyle(Theme.tertiaryText)
                }
                HStack(spacing: Theme.Spacing.small) { actions() }
                    .padding(.top, Theme.Spacing.small)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.xLarge)
    }
}

/// Play and Shuffle buttons for a list of songs fetched on demand.
struct PlayButtons: View {
    let songs: @MainActor () async throws -> [Song]

    @Environment(ServerSession.self) private var session
    @State private var errorMessage: String?

    var body: some View {
        Button("Play", tempus: .play) { start(shuffled: false) }
            .buttonStyle(.borderedProminent)
            // The button is filled with the accent, which is also the icons' color.
            .tempusIconKeepsForeground()
        Button("Shuffle", tempus: .shuffle) { start(shuffled: true) }
            .buttonStyle(.bordered)
            .alert("Couldn't play", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private func start(shuffled: Bool) {
        Task {
            do {
                let list = try await songs()
                guard !list.isEmpty else { return }
                if shuffled {
                    session.player.playShuffled(list)
                } else {
                    session.player.play(list)
                }
            } catch let error as SubsonicError {
                errorMessage = error.userMessage
            } catch {
                errorMessage = "Something went wrong."
            }
        }
    }
}

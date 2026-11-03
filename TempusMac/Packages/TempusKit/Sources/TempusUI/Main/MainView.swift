import AppCore
import SwiftUI

/// Where the sidebar can go.
enum SidebarDestination: String, Hashable, CaseIterable, Identifiable {
    case nowPlaying, home, search
    case albums, artists, genres, playlists, folders
    case podcasts, radio, shares, downloads

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .nowPlaying: "Now Playing"
        case .home: "Home"
        case .search: "Search"
        case .albums: "Albums"
        case .artists: "Artists"
        case .genres: "Genres"
        case .playlists: "Playlists"
        case .folders: "Music Folders"
        case .podcasts: "Podcasts"
        case .radio: "Radio"
        case .shares: "Shares"
        case .downloads: "Downloads"
        }
    }

    var systemImage: String {
        switch self {
        case .nowPlaying: "play.circle"
        case .home: "house"
        case .search: "magnifyingglass"
        case .albums: "square.stack"
        case .artists: "music.mic"
        case .genres: "guitars"
        case .playlists: "music.note.list"
        case .folders: "folder"
        case .podcasts: "mic"
        case .radio: "dot.radiowaves.left.and.right"
        case .shares: "square.and.arrow.up"
        case .downloads: "arrow.down.circle"
        }
    }

    static let sections: [(title: String?, items: [Self])] = [
        (nil, [.nowPlaying, .home, .search]),
        ("Library", [.albums, .artists, .genres, .playlists, .folders]),
        ("More", [.podcasts, .radio, .shares, .downloads]),
    ]

    /// ⌘1 to ⌘9 in the Go menu.
    static let shortcutOrder: [Self] = [
        .home,
        .search,
        .albums,
        .artists,
        .genres,
        .playlists,
        .podcasts,
        .radio,
        .downloads,
    ]
}

/// Which panel the inspector shows, as upstream's lyrics and queue buttons.
enum InspectorPanel: String, CaseIterable, Identifiable {
    case lyrics = "Lyrics"
    case queue = "Queue"

    var id: Self {
        self
    }
}

/// The signed-in window: sidebar, content, player bar along the bottom and the lyrics/queue inspector.
struct MainView: View {
    let session: ServerSession

    @Environment(Navigator.self) private var navigator
    @Environment(AppModel.self) private var model
    @State private var sheets = SheetPresenter()
    @SceneStorage("inspectorShown") private var showsInspector = false
    @SceneStorage("inspectorPanel") private var panel = InspectorPanel.queue

    var body: some View {
        @Bindable var navigator = navigator
        // The lyrics/queue panel is a fixed-width column inside the detail rather than SwiftUI's
        // `.inspector`, which overflowed narrow windows instead of resizing them. With fixed
        // widths, sidebar + content + panel always fit `Theme.Size.windowMinWidth`.
        NavigationSplitView {
            sidebar
        } detail: {
            HStack(spacing: 0) {
                Group {
                    if let route = navigator.path.last {
                        RouteView(route: route).id(navigator.path.count)
                    } else {
                        detail
                    }
                }
                // Wide content (a table's ideal width) must shrink, never push the panel or the
                // player bar out of the window.
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .safeAreaInset(edge: .top, spacing: 0) { offlineBanner }
                if showsInspector {
                    Divider()
                    PlayerInspector(session: session, panel: $panel)
                        .frame(width: Theme.Size.inspectorWidth)
                        .layoutPriority(1)
                        .transition(.move(edge: .trailing))
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PlayerBar(player: session.player, onTogglePanel: toggle) {
                    navigator.selection = .nowPlaying
                }
            }
            .animation(.snappy, value: showsInspector)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if !navigator.path.isEmpty {
                    Button("Back", systemImage: "chevron.left") { navigator.path.removeLast() }
                        .help("Back")
                }
            }
            ToolbarItem {
                Button("Lyrics and Queue", systemImage: "sidebar.trailing") { showsInspector.toggle() }
                    .help("Show or hide lyrics and the queue")
            }
        }
        .onKeyPress(.space) {
            session.player.togglePlayPause()
            return .handled
        }
        .navigationTitle(navigator.selection.title)
        .environment(session)
        .environment(sheets)
        .sheet(item: $sheets.current) { sheet in
            PresentedSheet(sheet: sheet)
                .environment(session)
                .environment(sheets)
                .environment(navigator)
                .environment(\.artwork, session.artwork)
        }
        .onChange(of: session.features.hasPodcasts) { _, has in
            if !has, navigator.selection == .podcasts {
                navigator.selection = .home
            }
        }
        .onChange(of: session.features.hasShares) { _, has in
            if !has, navigator.selection == .shares {
                navigator.selection = .home
            }
        }
    }

    private var visibleSections: [(title: String?, items: [SidebarDestination])] {
        SidebarDestination.sections.map { section in
            (section.title, section.items.filter { item in
                switch item {
                case .podcasts: session.features.hasPodcasts
                case .shares: session.features.hasShares
                default: true
                }
            })
        }
    }

    private var sidebar: some View {
        @Bindable var navigator = navigator
        return List(selection: $navigator.selection) {
            ForEach(visibleSections, id: \.items) { section in
                Section {
                    ForEach(section.items) { item in
                        Label(item.title, systemImage: item.systemImage)
                            .badge(item == .downloads ? downloadBadge : 0)
                            .tag(item)
                    }
                } header: {
                    if let title = section.title {
                        Text(title)
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: Theme.Size.sidebarMinWidth, ideal: 220)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                LibraryPicker(session: session)
                ServerMenu(session: session)
            }
        }
    }

    private var downloadBadge: Int {
        session.downloads.active.count + session.downloads.waiting.count
    }

    @ViewBuilder private var detail: some View {
        switch navigator.selection {
        case .nowPlaying: NowPlayingView(session: session)
        case .home: HomeView()
        case .search: SearchView()
        case .albums: AlbumsView()
        case .artists: ArtistsView()
        case .genres: GenresView()
        case .playlists: PlaylistsView()
        case .folders: FoldersView()
        case .podcasts: PodcastsView()
        case .radio: RadioView()
        case .shares: SharesView()
        case .downloads: DownloadsView()
        }
    }

    @ViewBuilder private var offlineBanner: some View {
        if session.isOffline {
            HStack(spacing: Theme.Spacing.small) {
                Text("Offline mode: showing saved data and downloads")
                Button("Reconnect") { Task { await model.connect(to: session.profile) } }
                    .buttonStyle(.link)
                    .help("Try the server again")
            }
            .font(.caption.weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.xSmall)
            .background(.red.opacity(0.15))
            .foregroundStyle(.red)
        }
    }

    /// The bar's lyrics and queue buttons open that panel, or close it if it's already showing.
    private func toggle(_ requested: InspectorPanel) {
        if showsInspector, panel == requested {
            showsInspector = false
        } else {
            panel = requested
            showsInspector = true
        }
    }
}

/// Upstream's library switcher: shown only when the server has more than one music folder.
private struct LibraryPicker: View {
    let session: ServerSession

    var body: some View {
        let folders = session.features.musicFolders
        if folders.count > 1 {
            Picker("Library", selection: Binding(
                get: { session.musicFolderID },
                set: { session.settings.setMusicFolderID($0, server: session.profile.id) }
            )) {
                Text("All Libraries").tag(String?.none)
                ForEach(folders) { folder in
                    Text(folder.name ?? "Library \(folder.id)").tag(Optional(folder.id))
                }
            }
            .pickerStyle(.menu)
            .padding(.horizontal, Theme.Spacing.medium)
            .help("Limit browsing and search to one library")
        }
    }
}

/// The server in use, with switching, editing and signing out.
private struct ServerMenu: View {
    let session: ServerSession

    @Environment(AppModel.self) private var model
    @State private var editing = false

    var body: some View {
        Menu {
            ForEach(model.servers) { server in
                Button(server.name) { Task { await model.connect(to: server) } }
                    .disabled(server.id == session.profile.id)
            }
            Divider()
            Button("Edit \(session.profile.name)…") { editing = true }
            Button("Sign Out") { Task { await model.signOut() } }
        } label: {
            Label(session.profile.name, systemImage: session.isOffline ? "bolt.horizontal.circle" : "server.rack")
        }
        .menuStyle(.borderlessButton)
        .padding(Theme.Spacing.medium)
        .sheet(isPresented: $editing) {
            ServerEditorView(existing: session.profile) { editing = false }
                .frame(width: Theme.Size.loginWidth)
                .padding(Theme.Spacing.large)
        }
    }
}

#Preview {
    RootView()
        .environment(PreviewSupport.model(signedIn: true))
        .frame(width: 1100, height: 700)
}

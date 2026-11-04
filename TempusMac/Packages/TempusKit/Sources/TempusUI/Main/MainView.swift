import AppCore
import DesignSystem
import SwiftUI

extension SidebarItem {
    /// Upstream's drawer and tab icons where it has the place, and the closest upstream icon
    /// otherwise. Upstream has no icon for internet radio (its Radio tab is text), so that keeps
    /// a symbol.
    var icon: TempusIcon? {
        switch self {
        case .nowPlaying: .play
        case .home: .home
        case .search: .search
        case .albums: .albums
        case .artists: .artists
        case .genres: .genres
        case .playlists: .playlist
        case .favorites: .favorite
        case .folders: .folder
        case .podcasts: .feed
        case .radio: nil
        case .shares: .share
        case .downloads: .playForWork
        }
    }

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
            .themedBackground(.background)
            .themedToolbar()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PlayerBar(player: session.player, stars: session.stars, onTogglePanel: toggle) {
                    navigator.selection = .nowPlaying
                }
            }
            .animation(.snappy, value: showsInspector)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if !navigator.path.isEmpty {
                    Button("Back", tempus: .arrowBack) { navigator.path.removeLast() }
                        .help("Back")
                }
            }
            ToolbarItem {
                Button { showsInspector.toggle() } label: {
                    Label { Text("Lyrics and Queue") } icon: { Image(systemName: "sidebar.trailing").tempusIconTinted()
                    }
                }
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
        // On the window rather than the sidebar, so View › Edit Sidebar… works with it collapsed.
        .sheet(isPresented: $navigator.isEditingSidebar) {
            SidebarEditorSheet(settings: session.settings, unavailable: session.unavailableSidebarItems)
        }
        // Hiding the open item moves to the first one still shown.
        .onChange(of: session.settings.sidebarLayout) { _, layout in
            guard !layout.isVisible(navigator.selection) else { return }
            let shown = SidebarSection.allCases.flatMap { shownItems(in: $0, layout: layout) }
            navigator.selection = shown.first ?? navigator.selection
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

    /// The items `section` shows: the ones left on in Edit Sidebar that this server has.
    private func shownItems(in section: SidebarSection, layout: SidebarLayout) -> [SidebarItem] {
        let unavailable = session.unavailableSidebarItems
        return layout.visibleItems(in: section).filter { !unavailable.contains($0) }
    }

    private var sidebar: some View {
        @Bindable var navigator = navigator
        let settings = session.settings
        let layout = settings.sidebarLayout
        return List(selection: $navigator.selection) {
            ForEach(SidebarSection.allCases) { section in
                let items = shownItems(in: section, layout: layout)
                if !items.isEmpty {
                    Section {
                        ForEach(items) { item in
                            SidebarLabel(item: item)
                                .badge(item == .downloads ? downloadBadge : 0)
                                .tag(item)
                                .contextMenu {
                                    Button("Hide “\(item.title)” from Sidebar") {
                                        settings.setSidebarLayout(settings.sidebarLayout.hiding(item))
                                    }
                                    .disabled(!layout.canHide(item))
                                    Divider()
                                    Button("Edit Sidebar…") { navigator.isEditingSidebar = true }
                                }
                        }
                        .onMove { offsets, destination in
                            settings.setSidebarLayout(
                                settings.sidebarLayout.moving(fromOffsets: offsets, toOffset: destination, among: items)
                            )
                        }
                    } header: {
                        if let title = section.title {
                            Text(title)
                        }
                    }
                }
            }
        }
        .themedBackground(.sidebar)
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
        case .favorites: FavoritesView()
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
                switch model.reconnectStatus {
                case .idle:
                    Text("Offline mode: showing saved data and downloads")
                case .retrying:
                    Text("Offline mode: showing saved data and downloads. Reconnecting…")
                case .waitingForPause:
                    Text("The server is back: switching to it when playback pauses")
                }
                Button(model.reconnectStatus == .waitingForPause ? "Reconnect Now" : "Reconnect") {
                    Task { await model.connect(to: session.profile) }
                }
                .buttonStyle(.link)
                .help("Try the server again")
            }
            .font(.inter(.caption, weight: .medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.xSmall)
            .background(Theme.error.opacity(0.15))
            .foregroundStyle(Theme.error)
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

struct SidebarLabel: View {
    let item: SidebarItem

    var body: some View {
        if let icon = item.icon {
            Label(item.title, tempus: icon)
        } else {
            Label {
                Text(item.title)
            } icon: {
                Image(systemName: "dot.radiowaves.left.and.right").tempusIconTinted()
            }
        }
    }
}

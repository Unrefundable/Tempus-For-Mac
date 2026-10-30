import AppCore
import SwiftUI

/// Where the sidebar can go. Everything but Now Playing is a placeholder until Phase 5.
enum SidebarDestination: String, Hashable, CaseIterable, Identifiable {
    case nowPlaying, home, search
    case albums, artists, genres, playlists, folders
    case podcasts, radio, downloads

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
        case .downloads: "arrow.down.circle"
        }
    }

    static let sections: [(title: String?, items: [Self])] = [
        (nil, [.nowPlaying, .home, .search]),
        ("Library", [.albums, .artists, .genres, .playlists, .folders]),
        ("More", [.podcasts, .radio, .downloads]),
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

    @SceneStorage("sidebarSelection") private var selection = SidebarDestination.home
    @SceneStorage("inspectorShown") private var showsInspector = false
    @SceneStorage("inspectorPanel") private var panel = InspectorPanel.queue

    var body: some View {
        // The lyrics/queue panel is a fixed-width column inside the detail rather than SwiftUI's
        // `.inspector`, which overflowed narrow windows instead of resizing them. With fixed
        // widths, sidebar + content + panel always fit `Theme.Size.windowMinWidth`.
        NavigationSplitView {
            sidebar
        } detail: {
            HStack(spacing: 0) {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .safeAreaInset(edge: .top, spacing: 0) { offlineBanner }
                if showsInspector {
                    Divider()
                    PlayerInspector(player: session.player, lyrics: session.lyrics, panel: $panel)
                        .frame(width: Theme.Size.inspectorWidth)
                        .transition(.move(edge: .trailing))
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PlayerBar(player: session.player, onTogglePanel: toggle) {
                    selection = .nowPlaying
                }
            }
            .animation(.snappy, value: showsInspector)
        }
        .toolbar {
            ToolbarItem {
                Button("Lyrics and Queue", systemImage: "sidebar.trailing") { showsInspector.toggle() }
                    .help("Show or hide lyrics and the queue")
            }
        }
        .onKeyPress(.space) {
            session.player.togglePlayPause()
            return .handled
        }
        .navigationTitle(selection.title)
    }

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(SidebarDestination.sections, id: \.items) { section in
                Section {
                    ForEach(section.items) { item in
                        Label(item.title, systemImage: item.systemImage).tag(item)
                    }
                } header: {
                    if let title = section.title {
                        Text(title)
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: Theme.Size.sidebarMinWidth, ideal: 220)
        .safeAreaInset(edge: .bottom) { ServerMenu(session: session) }
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .nowPlaying:
            NowPlayingView(player: session.player)
        default:
            ContentUnavailableView(
                selection.title,
                systemImage: selection.systemImage,
                description: Text("Coming in the next update.")
            )
        }
    }

    @ViewBuilder private var offlineBanner: some View {
        if session.isOffline {
            Text("Offline mode")
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

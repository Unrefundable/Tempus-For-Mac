import AppCore
import DesignSystem
import SwiftUI

/// The screens with their own toolbar controls. Everything else shows only the panel button.
enum ToolbarScreen: Equatable {
    case home, albums, playlists, podcasts, radio, shares, downloads, other

    init(selection: SidebarItem, route: Route?) {
        if let route {
            self = route == .allPlaylists ? .playlists : .other
            return
        }
        switch selection {
        case .home: self = .home
        case .albums: self = .albums
        case .playlists: self = .playlists
        case .podcasts: self = .podcasts
        case .radio: self = .radio
        case .shares: self = .shares
        case .downloads: self = .downloads
        default: self = .other
        }
    }

    /// The add button's title, for the screens that have one.
    var addTitle: String? {
        switch self {
        case .playlists: "New Playlist"
        case .podcasts: "Add Podcast"
        case .radio: "Add a New Radio"
        default: nil
        }
    }

    /// The refresh button's title, for the screens that have one.
    var refreshTitle: String? {
        switch self {
        case .home: "Reload Home"
        case .playlists, .shares: "Refresh"
        case .podcasts: "Check for New Episodes"
        default: nil
        }
    }
}

/// What a screen's toolbar button asks of the screen showing.
enum ScreenCommand: Equatable {
    case add, refresh, removeAll
}

/// Carries toolbar clicks to the screen showing. The buttons live in the window's toolbar, not
/// on the screens, so they stay put while screens change and can animate in and out.
@MainActor @Observable
final class ScreenCommands {
    struct Sent: Equatable {
        let command: ScreenCommand
        /// Tells two clicks of the same button apart.
        let serial: Int
    }

    private(set) var latest: Sent?

    func send(_ command: ScreenCommand) {
        latest = Sent(command: command, serial: (latest?.serial ?? 0) + 1)
    }
}

extension View {
    /// Runs `action` when the toolbar sends `command` while this screen shows.
    func onScreenCommand(_ command: ScreenCommand, perform action: @escaping () -> Void) -> some View {
        modifier(ScreenCommandHandler(command: command, action: action))
    }
}

private struct ScreenCommandHandler: ViewModifier {
    let command: ScreenCommand
    let action: () -> Void

    /// Optional, so a screen shown outside the main window (a preview) still works.
    @Environment(ScreenCommands.self) private var commands: ScreenCommands?

    func body(content: Content) -> some View {
        content.onChange(of: commands?.latest) { _, sent in
            if sent?.command == command {
                action()
            }
        }
    }
}

/// The toolbar's trailing controls: the screen's own, then the lyrics and queue button.
///
/// One toolbar item draws them all, with its own glass, because the toolbar itself swaps items
/// in and out with no animation. Here they fade and the glass stretches between screens.
struct ScreenToolbar: View {
    let screen: ToolbarScreen
    let togglePanel: @MainActor () -> Void

    @Environment(ServerSession.self) private var session
    @Environment(ScreenCommands.self) private var commands
    @Namespace private var glass
    /// Follows `screen` a step behind, so the width below is held before the controls change.
    @State private var shownScreen: ToolbarScreen
    @State private var contentWidth: CGFloat = 0
    /// The toolbar sizes the item to its new width at once. Holding the old width until the
    /// animation ends keeps the controls on their way out from being cut off.
    @State private var reservedWidth: CGFloat = 0

    init(screen: ToolbarScreen, togglePanel: @escaping @MainActor () -> Void) {
        self.screen = screen
        self.togglePanel = togglePanel
        _shownScreen = State(initialValue: screen)
    }

    private static let animation = Animation.snappy(duration: 0.3)
    private static let settleDelay = Duration.milliseconds(350)
    /// The toolbar's own glass buttons, measured on macOS 26.
    private static let buttonSize = CGSize(width: 37, height: 36)
    private static let groupSpacing = Theme.Spacing.small

    var body: some View {
        ToolbarGlassContainer(spacing: Self.groupSpacing) {
            HStack(spacing: Self.groupSpacing) {
                picker
                HStack(spacing: 0) {
                    buttons
                    panelButton
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        .frame(minWidth: reservedWidth, alignment: .trailing)
        .animation(Self.animation, value: shownScreen)
        .onChange(of: screen) { _, newScreen in
            reservedWidth = max(reservedWidth, contentWidth)
            shownScreen = newScreen
        }
        .task(id: shownScreen) {
            guard await (try? Task.sleep(for: Self.settleDelay)) != nil else { return }
            reservedWidth = 0
        }
    }

    @ViewBuilder private var picker: some View {
        @Bindable var settings = session.settings
        switch shownScreen {
        case .albums:
            Picker("Sort", selection: $settings.albumSort) {
                ForEach(AlbumSort.allCases) { Text($0.title).tag($0) }
            }
            .help("Sort albums")
            .modifier(PickerGlass(id: "albumSort", namespace: glass, height: Self.buttonSize.height))
        case .playlists:
            Picker("Sort", selection: $settings.playlistSort) {
                ForEach(PlaylistSort.allCases) { Text($0.title).tag($0) }
            }
            .help("Sort playlists")
            .modifier(PickerGlass(id: "playlistSort", namespace: glass, height: Self.buttonSize.height))
        case .downloads:
            Picker("Group by", selection: $settings.downloadGrouping) {
                ForEach(DownloadGrouping.allCases) { Text($0.title).tag($0) }
            }
            .help("Group downloads")
            .modifier(PickerGlass(id: "downloadGrouping", namespace: glass, height: Self.buttonSize.height))
        default:
            EmptyView()
        }
    }

    /// In fixed places, so a button two screens share (Refresh) stays put between them.
    @ViewBuilder private var buttons: some View {
        if let title = shownScreen.addTitle {
            button(title, icon: .add, id: "add") { commands.send(.add) }
        }
        if let title = shownScreen.refreshTitle {
            button(title, icon: .refresh, id: "refresh") { commands.send(.refresh) }
        }
        if shownScreen == .downloads {
            button("Remove All Downloads", icon: .delete, id: "removeAll") { commands.send(.removeAll) }
                .disabled(session.downloads.records.isEmpty)
        }
    }

    private func button(
        _ title: String,
        icon: TempusIcon,
        id: String,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(title, tempus: icon, action: action)
            .help(title)
            .modifier(ButtonGlass(id: id, namespace: glass, size: Self.buttonSize))
    }

    private var panelButton: some View {
        Button(action: togglePanel) {
            Label { Text("Lyrics and Queue") } icon: {
                Image(systemName: "sidebar.trailing").tempusIconTinted()
            }
        }
        .help("Show or hide lyrics and the queue")
        .modifier(ButtonGlass(id: "panel", namespace: glass, size: Self.buttonSize))
    }
}

/// Lets nearby glass shapes merge and morph on macOS 26 and later; just the content before.
private struct ToolbarGlassContainer<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// The buttons share one capsule, as the toolbar groups adjacent buttons.
private struct ButtonGlass: ViewModifier {
    let id: String
    let namespace: Namespace.ID
    let size: CGSize

    func body(content: Content) -> some View {
        let sized = content
            .frame(width: size.width, height: size.height)
            .contentShape(.rect)
            .transition(.opacity.combined(with: .scale(scale: 0.6)))
        if #available(macOS 26, *) {
            sized
                .glassEffect(.regular.interactive())
                .glassEffectID(id, in: namespace)
                .glassEffectUnion(id: "buttons", namespace: namespace)
        } else {
            sized
        }
    }
}

/// A menu gets a capsule of its own, as in the toolbar.
private struct PickerGlass: ViewModifier {
    let id: String
    let namespace: Namespace.ID
    let height: CGFloat

    func body(content: Content) -> some View {
        let shown = content
            .fixedSize()
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        if #available(macOS 26, *) {
            shown
                .frame(height: height)
                .glassEffect(.regular.interactive())
                .glassEffectID(id, in: namespace)
        } else {
            shown
        }
    }
}

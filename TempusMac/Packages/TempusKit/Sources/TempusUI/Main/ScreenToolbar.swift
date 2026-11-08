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
/// One toolbar item draws them all, with capsules of its own, because the toolbar itself swaps
/// items in and out with no animation. Here they fade and the capsules stretch between screens.
struct ScreenToolbar: View {
    let screen: ToolbarScreen
    /// Owned by the window, not this view: the toolbar resizes its item only when the window's
    /// toolbar content changes, so a width this view kept to itself would never shrink the item.
    let reservedWidth: CGFloat
    let reserve: @MainActor (CGFloat) -> Void
    let togglePanel: @MainActor () -> Void

    @Environment(ServerSession.self) private var session
    @Environment(ScreenCommands.self) private var commands
    /// Follows `screen` a step behind, so the width below is held before the controls change.
    @State private var shownScreen: ToolbarScreen
    @State private var contentWidth: CGFloat = 0

    init(
        screen: ToolbarScreen,
        reservedWidth: CGFloat,
        reserve: @escaping @MainActor (CGFloat) -> Void,
        togglePanel: @escaping @MainActor () -> Void
    ) {
        self.screen = screen
        self.reservedWidth = reservedWidth
        self.reserve = reserve
        self.togglePanel = togglePanel
        _shownScreen = State(initialValue: screen)
    }

    private static let animation = Animation.snappy(duration: 0.3)
    private static let settleDelay = Duration.milliseconds(350)
    /// The toolbar's own glass buttons, measured on macOS 26.
    private static let buttonSize = CGSize(width: 37, height: 36)
    private static let groupSpacing = Theme.Spacing.small

    var body: some View {
        HStack(spacing: Self.groupSpacing) {
            picker
            HStack(spacing: 0) {
                buttons
                panelButton
            }
            .toolbarCapsule()
        }
        // A group of its own, so each button keeps its own name: the toolbar otherwise names the
        // whole item after its first button.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Page controls")
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        .frame(minWidth: reservedWidth, alignment: .trailing)
        .animation(Self.animation, value: shownScreen)
        .onChange(of: screen) { _, newScreen in
            reserve(max(reservedWidth, contentWidth))
            shownScreen = newScreen
        }
        .task(id: shownScreen) {
            guard await (try? Task.sleep(for: Self.settleDelay)) != nil else { return }
            reserve(0)
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
            .modifier(ToolbarMenu(height: Self.buttonSize.height))
        case .playlists:
            Picker("Sort", selection: $settings.playlistSort) {
                ForEach(PlaylistSort.allCases) { Text($0.title).tag($0) }
            }
            .help("Sort playlists")
            .modifier(ToolbarMenu(height: Self.buttonSize.height))
        case .downloads:
            Picker("Group by", selection: $settings.downloadGrouping) {
                ForEach(DownloadGrouping.allCases) { Text($0.title).tag($0) }
            }
            .help("Group downloads")
            .modifier(ToolbarMenu(height: Self.buttonSize.height))
        default:
            EmptyView()
        }
    }

    /// In fixed places, so a button two screens share (Refresh) stays put between them.
    @ViewBuilder private var buttons: some View {
        if let title = shownScreen.addTitle {
            button(title, icon: .add) { commands.send(.add) }
        }
        if let title = shownScreen.refreshTitle {
            button(title, icon: .refresh) { commands.send(.refresh) }
        }
        if shownScreen == .downloads {
            button("Remove All Downloads", icon: .delete) { commands.send(.removeAll) }
                .disabled(session.downloads.records.isEmpty)
        }
    }

    private func button(_ title: String, icon: TempusIcon, action: @escaping @MainActor () -> Void) -> some View {
        Button(title, tempus: icon, action: action)
            .help(title)
            .accessibilityLabel(title)
            .modifier(ToolbarButton(size: Self.buttonSize))
    }

    private var panelButton: some View {
        Button(action: togglePanel) {
            Label { Text("Lyrics and Queue") } icon: {
                Image(systemName: "sidebar.trailing").tempusIconTinted()
            }
        }
        .help("Show or hide lyrics and the queue")
        .modifier(ToolbarButton(size: Self.buttonSize))
    }
}

/// A button the size of the toolbar's own, fading in and out between screens.
private struct ToolbarButton: ViewModifier {
    let size: CGSize

    func body(content: Content) -> some View {
        content
            .frame(width: size.width, height: size.height)
            .contentShape(.rect)
            .transition(.opacity.combined(with: .scale(scale: 0.6)))
    }
}

/// A menu in a capsule of its own, as in the toolbar.
private struct ToolbarMenu: ViewModifier {
    let height: CGFloat

    func body(content: Content) -> some View {
        content
            .fixedSize()
            .frame(height: height)
            .toolbarCapsule()
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
    }
}

extension View {
    /// The toolbar's capsule behind these controls, on macOS 26 and later.
    func toolbarCapsule() -> some View {
        modifier(ToolbarCapsule())
    }
}

/// The toolbar's glass capsule, drawn as plain shapes. SwiftUI's glass effect adds views of its
/// own that kept the places controls had on earlier screens and swallowed clicks meant for the
/// controls that replaced them; shapes are drawn only, so clicks always reach the buttons.
private struct ToolbarCapsule: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.background {
                Capsule()
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.7))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.08), radius: 2, y: 1)
                    .allowsHitTesting(false)
            }
        } else {
            content
        }
    }
}

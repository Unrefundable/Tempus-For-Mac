import AppCore
import AppKit
import Playback
import SwiftUI

/// The About window's credits, the Controls and Go menus, and ⌘F for search.
public struct TempusCommands: Commands {
    let model: AppModel?
    let navigator: Navigator

    public init(model: AppModel?) {
        self.model = model
        navigator = Navigator()
    }

    init(model: AppModel?, navigator: Navigator) {
        self.model = model
        self.navigator = navigator
    }

    static let seekStep: TimeInterval = 10

    public var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Tempus") { AboutPanel.show() }
        }
        CommandGroup(after: .textEditing) {
            Button("Search") { navigator.search() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(model?.session == nil)
        }
        CommandMenu("Controls") {
            let player = model?.session?.player
            Button(player?.status.isActive == true ? "Pause" : "Play") { player?.togglePlayPause() }
                .disabled(player?.queue.isEmpty ?? true)
            Button("Stop") { player?.stop() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(player?.queue.isEmpty ?? true)
            Button("Next") { player?.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(player == nil)
            Button("Previous") { player?.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(player == nil)
            Divider()
            Button("Skip Forward 10 Seconds") { player.map { $0.seek(to: $0.position + Self.seekStep) } }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(player?.queue.isEmpty ?? true)
            Button("Skip Back 10 Seconds") { player.map { $0.seek(to: $0.position - Self.seekStep) } }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(player?.queue.isEmpty ?? true)
            Divider()
            Button(player?.queue.isShuffled == true ? "Turn Shuffle Off" : "Shuffle") { player?.toggleShuffle() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(player == nil)
            Button("Repeat: \(Self.repeatTitle(player?.settings.repeatMode))") { player?.cycleRepeatMode() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(player == nil)
            Divider()
            starButton
        }
        CommandMenu("Go") {
            Button("Now Playing") { navigator.selection = .nowPlaying }
                .keyboardShortcut("0", modifiers: .command)
            ForEach(Array(SidebarDestination.shortcutOrder.enumerated()), id: \.element) { index, destination in
                Button(destination.title) { navigator.selection = destination }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
            Divider()
            Button("Back") {
                if !navigator.path.isEmpty {
                    navigator.path.removeLast()
                }
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(navigator.path.isEmpty)
        }
    }

    @ViewBuilder private var starButton: some View {
        let session = model?.session
        let song = session?.player.queue.current?.song
        Button(song
            .map { session?.stars.isStarred($0) == true } == true ? "Unstar Current Track" : "Star Current Track")
        {
            if let session, let song {
                Task { await session.stars.toggle(song) }
            }
        }
        .keyboardShortcut("l", modifiers: .command)
        .disabled(song == nil || song?.type == "radio")
    }

    static func repeatTitle(_ mode: RepeatMode?) -> String {
        switch mode {
        case .all: "All"
        case .one: "One"
        default: "Off"
        }
    }
}

/// The standard About panel with upstream's description, the licence and credits, as GPL-3.0 and
/// CLAUDE.md require.
enum AboutPanel {
    static let credits = """
    An open source, lightweight music client for Subsonic, OpenSubsonic and Navidrome, built natively \
    for the Mac.

    A port of Tempus by eddyizm (github.com/eddyizm/tempus), itself a fork of Tempo by \
    CappielloAntonio (from v3.9.0). Logo by SeattleGuy. Thanks to tvillega, herrerad85, MaFo-28 \
    and all Tempus contributors, and to unDraw for its illustrations.

    Released under the GNU General Public License v3.0. Built with AudioStreaming, GRDB and Nuke.
    """

    @MainActor
    static func show() {
        let text = NSAttributedString(
            string: credits,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: text])
        NSApplication.shared.activate()
    }
}

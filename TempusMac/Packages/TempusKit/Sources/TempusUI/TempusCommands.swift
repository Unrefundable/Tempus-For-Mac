import AppCore
import AppKit
import SwiftUI

/// The About window's credits and the Controls menu.
public struct TempusCommands: Commands {
    let model: AppModel?

    public init(model: AppModel?) {
        self.model = model
    }

    public var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Tempus") { AboutPanel.show() }
        }
        CommandMenu("Controls") {
            let player = model?.session?.player
            Button(player?.status.isActive == true ? "Pause" : "Play") { player?.togglePlayPause() }
                .disabled(player?.queue.isEmpty ?? true)
            Button("Next") { player?.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(player == nil)
            Button("Previous") { player?.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(player == nil)
            Divider()
            Button("Shuffle") { player?.toggleShuffle() }
                .disabled(player == nil)
            Button("Repeat") { player?.cycleRepeatMode() }
                .disabled(player == nil)
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

import AppCore
import AppKit
import DesignSystem
import Playback
import SwiftUI

/// The menu bar mini player: cover, titles, transport and the seek bar.
struct MenuBarPlayer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            if let session = model.session {
                let player = session.player
                HStack(spacing: Theme.Spacing.medium) {
                    ArtworkView(
                        coverArtID: player.queue.current?.song.coverArtID,
                        size: .thumbnail,
                        cornerRadius: Theme.Radius.artworkSmall,
                        placeholder: .song
                    )
                    .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.queue.current?.song.title ?? "Not Playing").font(.inter(.headline))
                        Text(player.queue.current?.song.artist ?? session.profile.name)
                            .font(.inter(.callout)).foregroundStyle(Theme.secondaryText)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                }
                SeekBar(player: player, compact: true)
                TransportControls(player: player)
                if let message = player.errorMessage {
                    Text(message).font(.inter(.caption)).foregroundStyle(Theme.error).lineLimit(2)
                }
            } else {
                Text("Not signed in").foregroundStyle(Theme.secondaryText)
            }
            Divider()
            HStack {
                Button("Open Tempus") {
                    openWindow(id: "main")
                    NSApplication.shared.activate()
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.tempusBorderless)
        }
        .padding(Theme.Spacing.large)
        .frame(width: 300)
        .environment(\.artwork, model.session?.artwork)
    }
}

/// The Dock icon's menu: what's playing and the transport, as Music offers.
@MainActor
final class DockMenu: NSObject {
    private let model: AppModel?

    init(model: AppModel?) {
        self.model = model
    }

    func menu() -> NSMenu {
        let menu = NSMenu()
        guard let player = model?.session?.player else { return menu }
        if let song = player.queue.current?.song {
            let title = NSMenuItem(
                title: [song.title, song.artist].compactMap(\.self).joined(separator: " — "),
                action: nil,
                keyEquivalent: ""
            )
            title.isEnabled = false
            menu.addItem(title)
            menu.addItem(.separator())
        }
        add(player.status.isActive ? "Pause" : "Play", #selector(togglePlay), to: menu, enabled: !player.queue.isEmpty)
        add("Next", #selector(next), to: menu, enabled: player.queue.nextItem(afterTrackEnded: false) != nil)
        add("Previous", #selector(previous), to: menu, enabled: !player.queue.isEmpty)
        return menu
    }

    private func add(_ title: String, _ action: Selector, to menu: NSMenu, enabled: Bool) {
        let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func togglePlay() {
        model?.session?.player.togglePlayPause()
    }

    @objc private func next() {
        model?.session?.player.next()
    }

    @objc private func previous() {
        model?.session?.player.previous()
    }
}

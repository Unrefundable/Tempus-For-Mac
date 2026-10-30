import AppCore
import Playback
import SwiftUI

/// Upstream's mini player, laid out the Mac way across the bottom of the window: cover and titles
/// (click to open Now Playing), transport and seek bar in the middle, then lyrics, queue and AirPlay.
struct PlayerBar: View {
    let player: PlayerController
    let onTogglePanel: (InspectorPanel) -> Void
    let onOpenNowPlaying: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.large) {
            nowPlaying
                .frame(minWidth: Theme.Size.playerBarCover, maxWidth: 280, alignment: .leading)
            VStack(spacing: 2) {
                TransportControls(player: player)
                SeekBar(player: player, compact: true)
                    .frame(minWidth: 0, maxWidth: 520)
            }
            .frame(maxWidth: .infinity)
            HStack(spacing: Theme.Spacing.medium) {
                Button("Lyrics", systemImage: "quote.bubble") { onTogglePanel(.lyrics) }
                Button("Queue", systemImage: "list.bullet") { onTogglePanel(.queue) }
                RoutePicker()
                    .frame(width: 24, height: 24)
                    .help("AirPlay and output devices")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .fixedSize()
        }
        .padding(.horizontal, Theme.Spacing.large)
        .frame(height: Theme.Size.playerBarHeight)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { errorLine }
    }

    private var nowPlaying: some View {
        Button(action: onOpenNowPlaying) {
            HStack(spacing: Theme.Spacing.medium) {
                ArtworkView(
                    coverArtID: player.queue.current?.song.coverArtID,
                    size: .thumbnail,
                    cornerRadius: Theme.Radius.artworkSmall
                )
                .frame(width: Theme.Size.playerBarCover, height: Theme.Size.playerBarCover)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.queue.current?.song.title ?? "Not Playing")
                        .font(.callout.weight(.medium))
                    Text(player.queue.current?.song.artist ?? " ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Show Now Playing")
    }

    @ViewBuilder private var errorLine: some View {
        if let message = player.errorMessage {
            Text(message)
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(1)
                .padding(.bottom, 2)
        }
    }
}

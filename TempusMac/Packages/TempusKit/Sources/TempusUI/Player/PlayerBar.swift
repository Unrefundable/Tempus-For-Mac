import AppCore
import DesignSystem
import Playback
import SwiftUI

/// Upstream's mini player, laid out the Mac way across the bottom of the window: cover and titles
/// (click to open Now Playing) with a heart to star the track, transport and seek bar in the
/// middle, then lyrics, queue and AirPlay.
struct PlayerBar: View {
    let player: PlayerController
    let stars: StarService
    let onTogglePanel: (InspectorPanel) -> Void
    let onOpenNowPlaying: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.large) {
            HStack(spacing: Theme.Spacing.small) {
                nowPlaying
                starButton
            }
            .frame(minWidth: Theme.Size.playerBarCover, maxWidth: 320, alignment: .leading)
            VStack(spacing: 2) {
                TransportControls(player: player)
                SeekBar(player: player, compact: true)
                    .frame(minWidth: 0, maxWidth: 520)
            }
            .frame(maxWidth: .infinity)
            HStack(spacing: Theme.Spacing.medium) {
                Button("Lyrics", tempus: .lyrics) { onTogglePanel(.lyrics) }
                Button("Queue", tempus: .queue) { onTogglePanel(.queue) }
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
                    cornerRadius: Theme.Radius.artworkSmall,
                    placeholder: .song
                )
                .frame(width: Theme.Size.playerBarCover, height: Theme.Size.playerBarCover)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.queue.current?.song.title ?? "Not Playing")
                        .font(.inter(.callout, weight: .medium))
                    Text(player.queue.current?.song.artist ?? " ")
                        .font(.inter(.caption))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Show Now Playing")
    }

    /// Stars or unstars the playing track, as ⌘L does.
    @ViewBuilder private var starButton: some View {
        let song = player.queue.current?.song
        let starred = song.map(stars.isStarred) ?? false
        Button(starred ? "Unstar" : "Star", tempus: starred ? .favorite : .favoritesOutlined) {
            if let song {
                Task { await stars.toggle(song) }
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(starred ? Theme.accent : .secondary)
        .help(starred ? "Unstar this track" : "Star this track")
        .disabled(!StarService.canStar(song))
    }

    @ViewBuilder private var errorLine: some View {
        if let message = player.errorMessage {
            Text(message)
                .font(.inter(.caption2))
                .foregroundStyle(.red)
                .lineLimit(1)
                .padding(.bottom, 2)
        }
    }
}

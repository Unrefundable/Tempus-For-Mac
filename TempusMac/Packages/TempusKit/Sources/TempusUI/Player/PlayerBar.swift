import AppCore
import DesignSystem
import Playback
import SwiftUI

/// Upstream's mini player, laid out the Mac way across the bottom of the window: cover and titles
/// (click to open Now Playing) with a heart to star the track, transport and seek bar in the
/// middle, then volume, lyrics, queue and AirPlay.
struct PlayerBar: View {
    let player: PlayerController
    let stars: StarService
    let onTogglePanel: (InspectorPanel) -> Void
    let onOpenNowPlaying: () -> Void

    /// The transport and seek bar take this share of the bar, between these widths. Below the
    /// floor the seek bar gets too short to aim; above the cap it's wider than it is useful.
    private static let controlsShare: CGFloat = 0.45
    private static let controlsWidths: ClosedRange<CGFloat> = 280 ... 520

    var body: some View {
        // The titles and the transport both shrink with the window, the titles truncating, and
        // the transport stays centered on the bar however wide the titles or buttons are.
        CenteredBarLayout(
            spacing: Theme.Spacing.large,
            middleShare: Self.controlsShare,
            middleWidths: Self.controlsWidths
        ) {
            HStack(spacing: Theme.Spacing.small) {
                nowPlaying
                starButton
            }
            VStack(spacing: 2) {
                TransportControls(player: player)
                SeekBar(player: player, compact: true)
            }
            HStack(spacing: Theme.Spacing.medium) {
                VolumeControl(player: player)
                Button("Lyrics", tempus: .lyrics) { onTogglePanel(.lyrics) }
                Button("Queue", tempus: .queue) { onTogglePanel(.queue) }
                RoutePicker()
                    .frame(width: 24, height: 24)
                    .help("AirPlay and output devices")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.tempusBorderless)
            .fixedSize()
        }
        .padding(.horizontal, Theme.Spacing.large)
        .frame(height: Theme.Size.playerBarHeight)
        .background(Theme.playerBar)
        .environment(\.rippleSurface, .playerBar)
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
                        .foregroundStyle(Theme.secondaryText)
                }
                .lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.tempusPlain)
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
        .buttonStyle(.tempusBorderless)
        .foregroundStyle(starred ? Theme.accent : Theme.secondaryText)
        .tempusIconKeepsForeground(!starred)
        .help(starred ? "Unstar this track" : "Star this track")
        .disabled(!StarService.canStar(song))
    }

    @ViewBuilder private var errorLine: some View {
        if let message = player.errorMessage {
            Text(message)
                .font(.inter(.caption2))
                .foregroundStyle(Theme.error)
                .lineLimit(1)
                .padding(.bottom, 2)
        }
    }
}

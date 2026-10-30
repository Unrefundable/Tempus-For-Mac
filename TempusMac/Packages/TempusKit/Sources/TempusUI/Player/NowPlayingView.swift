import AppCore
import Playback
import SwiftUI

/// Upstream's full player: large cover, title and artist, the format chip, the seek bar, transport,
/// and the speed and sleep-timer controls. Lyrics and the queue are in the inspector.
struct NowPlayingView: View {
    let player: PlayerController

    var body: some View {
        if let song = player.queue.current?.song {
            VStack(spacing: Theme.Spacing.large) {
                // The cover gives way first, so the controls always fit beside the inspector.
                ArtworkView(coverArtID: song.coverArtID, size: .original)
                    .frame(maxWidth: Theme.Size.nowPlayingArtwork, maxHeight: Theme.Size.nowPlayingArtwork)
                    .shadow(radius: 12, y: 6)
                    .layoutPriority(-1)
                VStack(spacing: Theme.Spacing.xSmall) {
                    Text(song.title ?? "Untitled").font(.title.bold())
                    Text(song.artist ?? "Unknown artist").font(.title3).foregroundStyle(.secondary)
                    if let album = song.album {
                        Text(album).font(.callout).foregroundStyle(.tertiary)
                    }
                }
                .multilineTextAlignment(.center)
                .lineLimit(2)
                if let quality = TrackFormatting.quality(of: song) {
                    Text(quality)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, Theme.Spacing.small)
                        .padding(.vertical, 3)
                        .background(Theme.accent.opacity(0.15), in: .capsule)
                }
                SeekBar(player: player)
                    .frame(maxWidth: Theme.Size.nowPlayingArtwork + 80)
                TransportControls(player: player, large: true)
                HStack(spacing: Theme.Spacing.xLarge) {
                    SpeedMenu(player: player)
                    SleepTimerMenu(player: player)
                }
            }
            .padding(Theme.Spacing.xLarge)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "Nothing Playing",
                systemImage: "music.note",
                description: Text("Play something from your library and it shows up here.")
            )
        }
    }
}

/// Upstream's speed button, "1.00x", with common rates.
private struct SpeedMenu: View {
    let player: PlayerController
    private static let rates = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        Menu(TrackFormatting.speed(player.settings.speed.rate)) {
            ForEach(Self.rates, id: \.self) { rate in
                Button(TrackFormatting.speed(rate)) {
                    player.setSpeed(PlaybackSpeed(rate: rate, pitch: player.settings.speed.pitch))
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Playback speed")
    }
}

/// Upstream's sleep timer: presets, end of track, and cancel, with the time left while it runs.
private struct SleepTimerMenu: View {
    let player: PlayerController

    var body: some View {
        Menu {
            ForEach(SleepTimer.presetMinutes, id: \.self) { minutes in
                Button("\(minutes) minutes") {
                    if let timer = SleepTimer.starting(minutes: minutes, now: .now) {
                        player.setSleepTimer(timer)
                    }
                }
            }
            Button("End of track") { player.setSleepTimer(.endOfTrack) }
            if player.settings.sleepTimer != .off {
                Divider()
                Button("Cancel Timer") { player.setSleepTimer(.off) }
            }
        } label: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Label(label(now: context.date), systemImage: "moon.zzz")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Sleep timer")
    }

    private func label(now: Date) -> String {
        switch player.settings.sleepTimer {
        case .off: "Sleep Timer"
        case .endOfTrack: "End of track"
        case .until: TrackFormatting.time(player.settings.sleepTimer.remaining(now: now) ?? 0)
        }
    }
}

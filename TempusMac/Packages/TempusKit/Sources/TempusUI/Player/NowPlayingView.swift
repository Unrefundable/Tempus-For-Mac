import AppCore
import AppKit
import Playback
import SubsonicAPI
import SwiftUI

/// Upstream's full player: large cover, title and artist (click to open the album or artist),
/// the format chip, the seek bar, transport, the star, rating and track actions, and the speed and
/// sleep-timer controls. Lyrics and the queue are in the inspector.
struct NowPlayingView: View {
    let session: ServerSession

    @Environment(Navigator.self) private var navigator
    @Environment(SheetPresenter.self) private var sheets

    private var player: PlayerController {
        session.player
    }

    var body: some View {
        if let song = player.queue.current?.song {
            VStack(spacing: Theme.Spacing.large) {
                // The cover gives way first, so the controls always fit beside the inspector.
                ArtworkView(coverArtID: song.coverArtID, size: .original)
                    .frame(maxWidth: Theme.Size.nowPlayingArtwork, maxHeight: Theme.Size.nowPlayingArtwork)
                    .shadow(radius: 12, y: 6)
                    .layoutPriority(-1)
                VStack(spacing: Theme.Spacing.xSmall) {
                    Button { song.albumID.map { navigator.open(.album(id: $0)) } } label: {
                        Text(title(of: song)).font(.title.bold())
                    }
                    .buttonStyle(.plain)
                    .help("Go to the album")
                    Button { song.artistID.map { navigator.open(.artist(id: $0)) } } label: {
                        Text(song.artist ?? "Unknown artist").font(.title3).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Go to the artist")
                    if let album = song.album {
                        Text(album).font(.callout).foregroundStyle(.tertiary)
                    }
                }
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .contextMenu {
                    Button("Copy Title") { copy(song.title) }
                    Button("Copy Artist") { copy(song.artist) }
                }
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
                if song.type != RadioStation.songType {
                    TrackActions(session: session, song: song)
                }
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

    private func title(of song: Song) -> String {
        let title = song.title ?? "Untitled"
        guard session.settings.showsTrackNumber, let track = song.track else { return title }
        return "\(track). \(title)"
    }

    private func copy(_ text: String?) {
        guard let text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Upstream's four cover buttons and the heart: star, rating, download, add to playlist,
/// Instant Mix.
private struct TrackActions: View {
    let session: ServerSession
    let song: Song

    @Environment(SheetPresenter.self) private var sheets

    var body: some View {
        HStack(spacing: Theme.Spacing.large) {
            let starred = session.stars.isStarred(song)
            Button(starred ? "Unstar" : "Star", systemImage: starred ? "heart.fill" : "heart") {
                Task { await session.stars.toggle(song) }
            }
            .foregroundStyle(starred ? Theme.accent : .primary)
            RatingControl(rating: session.stars.rating(of: song)) { rating in
                Task { await session.stars.setRating(rating, for: song) }
            }
            if session.downloads.isDownloaded(song.id) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary).help("Downloaded")
            } else if session.downloads.isPending(song.id) {
                ProgressView().controlSize(.small)
            } else {
                Button("Download", systemImage: "arrow.down.circle") { session.downloads.download([song]) }
            }
            Button("Add to Playlist", systemImage: "text.badge.plus") { sheets.present(.addToPlaylist([song])) }
            Button("Instant Mix", systemImage: "wand.and.stars") {
                Task {
                    do throws(SubsonicError) {
                        try await session.player.playNext(session.sources.instantMix(for: song))
                    } catch {
                        sheets.present(.message(title: "Instant Mix", text: error.userMessage))
                    }
                }
            }
            .help("Play this again, then similar songs")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.title3)
        .overlay(alignment: .bottom) {
            if let message = session.stars.errorMessage {
                Text(message).font(.caption).foregroundStyle(.red).offset(y: 20)
            }
        }
    }
}

/// Five stars; clicking the current rating clears it.
struct RatingControl: View {
    let rating: Int
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1 ... 5, id: \.self) { value in
                Button { onChange(value == rating ? 0 : value) } label: {
                    Image(systemName: value <= rating ? "star.fill" : "star")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(value) stars")
            }
        }
        .font(.callout)
        .foregroundStyle(Theme.accent)
        .help("Rating")
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

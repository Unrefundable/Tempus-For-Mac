import AppCore
import DesignSystem
import Playback
import SubsonicAPI
import SwiftUI

/// The inspector beside the content: lyrics or the queue.
struct PlayerInspector: View {
    let session: ServerSession
    @Binding var panel: InspectorPanel

    private var player: PlayerController {
        session.player
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: $panel) {
                ForEach(InspectorPanel.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(Theme.Spacing.medium)
            switch panel {
            case .lyrics:
                LyricsPanel(
                    player: player,
                    service: session.lyrics,
                    settings: session.settings,
                    serverID: session.profile.id
                )
            case .queue: QueuePanel(session: session)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Upstream's "Playing Next": count and length, then each entry. Earlier tracks are dimmed and the
/// current one highlighted. Double-click plays an entry; Delete or the context menu removes one.
struct QueuePanel: View {
    let session: ServerSession

    @Environment(SheetPresenter.self) private var sheets
    @State private var errorMessage: String?

    private var player: PlayerController {
        session.player
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Playing Next").font(.inter(.headline))
                    Text(TrackFormatting.queueSummary(player.queue.items.map(\.song)))
                        .font(.inter(.caption))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Button("Shuffle Upcoming", tempus: .shuffle) { player.shuffleUpcoming() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.tempusBorderless)
                    .disabled(player.queue.items.count < 3)
                Menu("Queue", tempus: .moreVert) {
                    Button("Save as Playlist…") { sheets.present(.newPlaylist(player.queue.items.map(\.song))) }
                        .disabled(player.queue.isEmpty)
                    if session.settings.syncsPlayQueue {
                        Button("Load Queue from Server") { loadServerQueue() }
                    }
                    Divider()
                    Button("Clear Queue", role: .destructive) { player.clear() }
                        .disabled(player.queue.isEmpty)
                }
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, Theme.Spacing.medium)
            if let errorMessage {
                Text(errorMessage).font(.inter(.caption)).foregroundStyle(Theme.error).padding(
                    .horizontal,
                    Theme.Spacing.medium
                )
            }
            Group {
                if player.queue.isEmpty {
                    EmptyState(
                        art: .icon(.queue),
                        title: "Queue is empty",
                        message: Text("Drag songs here to add them.")
                    )
                } else {
                    list
                }
            }
            .dropDestination(for: SongTransfer.self) { items, _ in
                let songs = items.flatMap(\.songs)
                player.addToQueue(songs)
                return !songs.isEmpty
            }
        }
    }

    private func loadServerQueue() {
        Task {
            do throws(SubsonicError) {
                try await session.listening.loadServerQueue()
                errorMessage = nil
            } catch {
                errorMessage = error.userMessage
            }
        }
    }

    private var list: some View {
        let currentIndex = player.queue.currentIndex ?? 0
        return List {
            ForEach(Array(player.queue.items.enumerated()), id: \.element.id) { index, item in
                QueueRow(song: item.song, isCurrent: item.id == player.queue.currentID)
                    .opacity(index < currentIndex ? Theme.playedOpacity : 1)
                    .contentShape(.rect)
                    .onTapGesture(count: 2) { player.jump(to: item.id) }
                    .contextMenu {
                        Button("Play") { player.jump(to: item.id) }
                        Button("Remove from Queue") { player.remove(item.id) }
                            .disabled(item.id == player.queue.currentID)
                        Divider()
                        SongMenu(songs: [item.song])
                    }
            }
            .onMove { source, destination in
                guard let from = source.first else { return }
                let id = player.queue.items[from].id
                player.move(id, to: destination > from ? destination - 1 : destination)
            }
        }
        .listStyle(.plain)
    }
}

private struct QueueRow: View {
    let song: Song
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            ArtworkView(
                coverArtID: song.coverArtID,
                size: .thumbnail,
                cornerRadius: Theme.Radius.artworkSmall,
                placeholder: .song
            )
            .frame(width: Theme.Size.queueCover, height: Theme.Size.queueCover)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title ?? "Untitled")
                    .font(.inter(.callout, weight: isCurrent ? .bold : .regular))
                    .foregroundStyle(isCurrent ? Theme.accent : Theme.primaryText)
                Text([song.artist, song.duration.map { TrackFormatting.time(TimeInterval($0)) }]
                    .compactMap(\.self).joined(separator: "  •  "))
                    .font(.inter(.caption))
                    .foregroundStyle(Theme.secondaryText)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if isCurrent {
                NowPlayingBars()
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.vertical, 2)
    }
}

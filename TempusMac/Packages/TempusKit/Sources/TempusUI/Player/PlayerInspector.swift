import AppCore
import Playback
import SubsonicAPI
import SwiftUI

/// The inspector beside the content: lyrics or the queue.
struct PlayerInspector: View {
    let player: PlayerController
    let lyrics: LyricsService
    @Binding var panel: InspectorPanel

    var body: some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: $panel) {
                ForEach(InspectorPanel.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(Theme.Spacing.medium)
            switch panel {
            case .lyrics: LyricsPanel(player: player, service: lyrics)
            case .queue: QueuePanel(player: player)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Upstream's "Playing Next": count and length, then each entry. Earlier tracks are dimmed and the
/// current one highlighted. Double-click plays an entry; Delete or the context menu removes one.
struct QueuePanel: View {
    let player: PlayerController

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Playing Next").font(.headline)
                    Text(TrackFormatting.queueSummary(player.queue.items.map(\.song)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Shuffle Upcoming", systemImage: "shuffle") { player.shuffleUpcoming() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(player.queue.items.count < 3)
            }
            .padding(.horizontal, Theme.Spacing.medium)
            if player.queue.isEmpty {
                ContentUnavailableView("Queue is empty", systemImage: "music.note.list")
            } else {
                list
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
            ArtworkView(coverArtID: song.coverArtID, size: .thumbnail, cornerRadius: Theme.Radius.artworkSmall)
                .frame(width: Theme.Size.queueCover, height: Theme.Size.queueCover)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title ?? "Untitled")
                    .font(.callout.weight(isCurrent ? .bold : .regular))
                    .foregroundStyle(isCurrent ? Theme.accent : .primary)
                Text([song.artist, song.duration.map { TrackFormatting.time(TimeInterval($0)) }]
                    .compactMap(\.self).joined(separator: "  •  "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel("Now playing")
            }
        }
        .padding(.vertical, 2)
    }
}

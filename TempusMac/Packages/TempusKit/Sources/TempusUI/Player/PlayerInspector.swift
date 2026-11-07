import AppCore
import DesignSystem
import Playback
import SubsonicAPI
import SwiftUI
import UniformTypeIdentifiers

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
            // Both stay built and only the chosen one shows, so switching doesn't rebuild either:
            // rebuilt, the lyrics went back to loading and the lists redrew their lines, which
            // flashed for a moment.
            ZStack(alignment: .top) {
                LyricsPanel(
                    player: player,
                    service: session.lyrics,
                    settings: session.settings,
                    serverID: session.profile.id
                )
                .shown(panel == .lyrics)
                QueuePanel(session: session, isShown: panel == .queue)
                    .shown(panel == .queue)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private extension View {
    /// Shows this view, or keeps it in place but invisible and out of reach.
    func shown(_ isShown: Bool) -> some View {
        opacity(isShown ? 1 : 0)
            .allowsHitTesting(isShown)
            .accessibilityHidden(!isShown)
    }
}

/// Upstream's "Playing Next": count and length, then each entry. Earlier tracks are dimmed and the
/// current one highlighted. Double-click plays an entry, dragging one onto another moves it there,
/// and the context menu removes one.
struct QueuePanel: View {
    let session: ServerSession
    /// Whether the queue is the panel showing. Coming into view brings the playing song back to the top.
    let isShown: Bool

    @Environment(SheetPresenter.self) private var sheets
    @State private var errorMessage: String?
    @State private var position = ScrollPosition(idType: QueueItem.ID.self)

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
                .tempusMenu()
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

    /// Opens on the playing song at the top, goes back to it each time the queue is shown, and
    /// keeps it there as the queue moves on.
    private var list: some View {
        rows
            .scrollPosition($position, anchor: .top)
            .onAppear { scrollToCurrent(animated: false) }
            .onChange(of: isShown) { _, shown in
                if shown {
                    scrollToCurrent(animated: false)
                }
            }
            .onChange(of: player.queue.currentID) { scrollToCurrent(animated: true) }
    }

    private func scrollToCurrent(animated: Bool) {
        guard let id = player.queue.currentID else { return }
        if animated {
            withAnimation(.smooth) { position.scrollTo(id: id, anchor: .top) }
        } else {
            position.scrollTo(id: id, anchor: .top)
        }
    }

    /// A scroll view rather than a `List`: on the Mac a list can't be scrolled to an entry with an
    /// animation, and jumps to entries it hasn't drawn land off target. Rows here are all one
    /// height, so a scroll to the playing song lands exactly and glides there.
    private var rows: some View {
        let items = player.queue.items
        let currentIndex = player.queue.currentIndex ?? 0
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    QueueEntry(
                        item: item,
                        isCurrent: item.id == player.queue.currentID,
                        isPlayed: index < currentIndex,
                        isLast: index == items.count - 1
                    ) { moved in
                        player.move(moved, to: index)
                    }
                    .contextMenu {
                        Button("Play") { player.jump(to: item.id) }
                        Button("Remove from Queue") { player.remove(item.id) }
                            .disabled(item.id == player.queue.currentID)
                        Divider()
                        SongMenu(songs: [item.song])
                    }
                    .onTapGesture(count: 2) { player.jump(to: item.id) }
                }
            }
            .scrollTargetLayout()
        }
    }
}

/// A queue entry to drag onto another to take its place.
struct QueueItemTransfer: Codable, Transferable {
    let id: QueueItem.ID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .tempusQueueItem)
    }
}

extension UTType {
    /// A queue entry being moved within the queue (declared in the app's Info.plist).
    static let tempusQueueItem = UTType(exportedAs: "io.github.unrefundable.TempusMac.queue-item")
}

/// One row of the queue: dimmed once played, a line under it as a list draws, and a drop target
/// for moving another entry into its place.
private struct QueueEntry: View {
    let item: QueueItem
    let isCurrent: Bool
    let isPlayed: Bool
    let isLast: Bool
    let onMoveHere: (QueueItem.ID) -> Void

    @State private var isTargeted = false

    var body: some View {
        QueueRow(song: item.song, isCurrent: isCurrent)
            .opacity(isPlayed ? Theme.playedOpacity : 1)
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.xSmall)
            .contentShape(.rect)
            .background {
                if isTargeted {
                    Rectangle().fill(Theme.accent).opacity(Self.dropHighlightOpacity)
                }
            }
            .overlay(alignment: .bottom) {
                if !isLast {
                    Divider().padding(.leading, Self.separatorInset)
                }
            }
            .draggable(QueueItemTransfer(id: item.id)) {
                QueueRow(song: item.song, isCurrent: false)
                    .frame(width: Theme.Size.inspectorWidth - 2 * Theme.Spacing.medium)
            }
            .dropDestination(for: QueueItemTransfer.self) { moved, _ in
                guard let id = moved.first?.id, id != item.id else { return false }
                onMoveHere(id)
                return true
            } isTargeted: { isTargeted = $0 }
    }

    private static let dropHighlightOpacity = 0.18
    /// Lines start under the titles, past the cover, as a list's separators do.
    private static let separatorInset = Theme.Spacing.medium + Theme.Size.queueCover + Theme.Spacing.medium
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

import AppCore
import CoreTransferable
import DesignSystem
import SubsonicAPI
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Songs dragged within Tempus (declared in the app's Info.plist).
    static let tempusSongs = UTType(exportedAs: "io.github.unrefundable.TempusMac.songs")
}

/// Songs being dragged: onto the queue, or onto a playlist in the sidebar.
struct SongTransfer: Codable, Transferable {
    let songs: [Song]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .tempusSongs)
    }
}

/// The one track list, in upstream's row: cover, title over `artist • time • quality`, then the
/// starred and downloaded marks. Double-click or Return plays from that row; the context menu has
/// everything else; rows drag onto the queue.
struct TrackTable: View {
    let songs: [Song]
    /// The playlist they're from, remembered by downloads.
    var source: DownloadManager.Source?
    /// Covers lead each row, except on an album's own page, where every cover would be the same
    /// and the track number stands in its place (upstream's `showCoverArt`).
    var showsArtwork = true
    /// Names the album under each title instead of the artist, for an artist's own page
    /// (upstream's `showAlbum`).
    var subtitleShowsAlbum = false

    @Environment(ServerSession.self) private var session
    @State private var selection: Set<Int> = []

    private struct Row: Identifiable {
        let id: Int
        let song: Song
    }

    var body: some View {
        let rows = songs.enumerated().map { Row(id: $0.offset, song: $0.element) }
        let current = session.player.queue.current?.song.id
        Table(of: Row.self, selection: $selection) {
            TableColumn("Title") { row in
                TrackRow(
                    song: row.song,
                    number: showsArtwork ? nil : TrackFormatting.rowNumber(row.song, at: row.id),
                    subtitleShowsAlbum: subtitleShowsAlbum,
                    isCurrent: row.song.id == current,
                    isStarred: session.stars.isStarred(row.song),
                    download: TrackDownloadMark.of(row.song, in: session.downloads)
                )
            }
        } rows: {
            ForEach(rows) { row in
                TableRow(row)
                    .draggable(SongTransfer(songs: dragged(row, rows: rows)))
            }
        }
        .tableColumnHeaders(.hidden)
        .alternatingRowBackgrounds(.disabled)
        .frame(minWidth: 0, minHeight: 0)
        .contextMenu(forSelectionType: Int.self) { ids in
            let chosen = ids.sorted().compactMap { rows.indices.contains($0) ? rows[$0].song : nil }
            if !chosen.isEmpty {
                SongMenu(songs: chosen, source: source)
            }
        } primaryAction: { ids in
            guard let first = ids.min() else { return }
            session.player.play(songs, startingAt: first)
        }
    }

    /// Dragging a selected row takes the whole selection along.
    private func dragged(_ row: Row, rows: [Row]) -> [Song] {
        guard selection.contains(row.id) else { return [row.song] }
        return selection.sorted().compactMap { rows.indices.contains($0) ? rows[$0].song : nil }
    }
}

/// Whether a song is saved for offline, or on its way.
enum TrackDownloadMark {
    /// Read by the list, not the row: a cell can lay out where the session isn't in its environment.
    @MainActor
    static func of(_ song: Song, in downloads: DownloadManager) -> TrackRow.DownloadMark? {
        if downloads.isDownloaded(song.id) {
            return .downloaded
        }
        return downloads.isPending(song.id) ? .pending : nil
    }
}

/// One track: its cover (or track number), title and subtitle, and marks. The playing track shows
/// the equalizer over its cover, as upstream dims the cover under its play icon.
struct TrackRow: View {
    enum DownloadMark { case downloaded, pending }

    let song: Song
    /// The album track number in place of the cover; nil shows the cover.
    let number: String?
    let subtitleShowsAlbum: Bool
    let isCurrent: Bool
    let isStarred: Bool
    let download: DownloadMark?

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            leading
                .frame(width: Theme.Size.trackRowCover, height: Theme.Size.trackRowCover)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title ?? "Untitled")
                    .font(.inter(.body))
                    .foregroundStyle(isCurrent ? Theme.accent : Theme.primaryText)
                let subtitle = TrackFormatting.listSubtitle(of: song, showingAlbum: subtitleShowsAlbum)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.inter(.subheadline))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            marks
        }
        .padding(.vertical, Theme.Spacing.xSmall)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var leading: some View {
        if let number {
            if isCurrent {
                nowPlaying.foregroundStyle(Theme.accent)
            } else {
                Text(number).foregroundStyle(Theme.secondaryText).monospacedDigit()
            }
        } else {
            ArtworkView(
                coverArtID: song.coverArtID,
                size: .thumbnail,
                cornerRadius: Theme.Radius.artworkSmall,
                placeholder: .song
            )
            .overlay {
                if isCurrent {
                    RoundedRectangle(cornerRadius: Theme.Radius.artworkSmall)
                        .fill(.black.opacity(Theme.nowPlayingScrim))
                        .overlay { nowPlaying.foregroundStyle(.white) }
                }
            }
        }
    }

    private var nowPlaying: some View {
        NowPlayingBars()
    }

    private var marks: some View {
        HStack(spacing: Theme.Spacing.small) {
            if isStarred {
                TempusIconImage(.favorite, accessibilityName: Text("Starred"))
                    .tempusIconSize(Theme.Size.trackMark)
                    .foregroundStyle(Theme.accent)
            }
            switch download {
            case .downloaded:
                TempusIconImage(.download, accessibilityName: Text("Downloaded"))
                    .tempusIconSize(Theme.Size.trackMark)
                    .foregroundStyle(Theme.secondaryText)
                    .tempusIconKeepsForeground()
            case .pending:
                ProgressView().controlSize(.mini)
            case nil:
                EmptyView()
            }
        }
    }
}

/// The modal sheets any screen can ask for.
@MainActor
@Observable
final class SheetPresenter {
    enum Sheet: Identifiable {
        case addToPlaylist([Song])
        case newPlaylist([Song])
        case trackInfo(Song)
        case share(ids: [String], name: String)
        case message(title: String, text: String)

        var id: String {
            switch self {
            case let .addToPlaylist(songs): "add-\(songs.map(\.id).joined(separator: ","))"
            case let .newPlaylist(songs): "new-\(songs.map(\.id).joined(separator: ","))"
            case let .trackInfo(song): "info-\(song.id)"
            case let .share(ids, _): "share-\(ids.joined(separator: ","))"
            case let .message(title, text): "message-\(title)-\(text)"
            }
        }
    }

    var current: Sheet?

    func present(_ sheet: Sheet) {
        current = sheet
    }
}

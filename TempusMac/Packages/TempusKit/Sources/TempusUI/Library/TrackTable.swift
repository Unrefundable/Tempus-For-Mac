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

/// The one track list: number, title, artist, album, length. Double-click or Return plays from
/// that row; the context menu has everything else; rows drag onto the queue.
struct TrackTable: View {
    let songs: [Song]
    /// The playlist they're from, remembered by downloads.
    var source: DownloadManager.Source?
    /// Numbers rows by position instead of track number: for any list that isn't one album or
    /// folder (playlists, favorites, search results), where track numbers repeat and jump about.
    var numbersByPosition = false

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
            TableColumn("#") { row in
                if row.song.id == current {
                    TempusIconImage(.equalizer, accessibilityName: Text("Now playing")).foregroundStyle(Theme.accent)
                } else {
                    Text(TrackFormatting.rowNumber(row.song, at: row.id, byPosition: numbersByPosition))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            // Room for three digits: favorites and downloads often run past 99 rows.
            .width(40)
            TableColumn("Title") { row in
                HStack(spacing: Theme.Spacing.xSmall) {
                    Text(row.song.title ?? "Untitled")
                        .foregroundStyle(row.song.id == current ? Theme.accent : .primary)
                    if session.stars.isStarred(row.song) {
                        TempusIconImage(.favorite, accessibilityName: Text("Starred"))
                            .tempusIconSize(Theme.Size.badgeIcon)
                            .foregroundStyle(Theme.accent)
                    }
                    if session.downloads.isDownloaded(row.song.id) {
                        TempusIconImage(.download, accessibilityName: Text("Downloaded"))
                            .tempusIconSize(Theme.Size.badgeIcon)
                            .foregroundStyle(.secondary)
                    } else if session.downloads.isPending(row.song.id) {
                        ProgressView().controlSize(.mini)
                    }
                }
            }
            .width(min: 120, ideal: 240)
            TableColumn("Artist") { row in Text(row.song.artist ?? "") }
                .width(min: 60, ideal: 140)
            TableColumn("Album") { row in Text(row.song.album ?? "") }
                .width(min: 60, ideal: 140)
            TableColumn("Time") { row in
                Text(row.song.duration.map { TrackFormatting.time(TimeInterval($0)) } ?? "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(50)
        } rows: {
            ForEach(rows) { row in
                TableRow(row)
                    .draggable(SongTransfer(songs: dragged(row, rows: rows)))
            }
        }
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

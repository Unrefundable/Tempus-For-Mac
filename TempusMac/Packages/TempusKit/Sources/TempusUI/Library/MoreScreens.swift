import AppCore
import AppKit
import DesignSystem
import Persistence
import SubsonicAPI
import SwiftUI

// MARK: Downloads

struct DownloadsView: View {
    @Environment(ServerSession.self) private var session
    @State private var confirmsDeleteAll = false

    private struct Group: Identifiable {
        let id: String
        let title: String
        let songs: [Song]
    }

    var body: some View {
        @Bindable var settings = session.settings
        let downloads = session.downloads
        VStack(spacing: 0) {
            status
            if downloads.records.isEmpty {
                EmptyState(
                    art: .illustration(.emptyList),
                    title: "No downloads",
                    message: Text("Download tracks, albums or playlists to play them offline.")
                )
            } else if settings.downloadGrouping == .track {
                TrackTable(songs: Self.ordered(downloads.downloads).map(\.song))
            } else {
                List(groups(settings.downloadGrouping)) { group in
                    DisclosureGroup {
                        ForEach(Array(group.songs.enumerated()), id: \.offset) { index, song in
                            Button { session.player.play(group.songs, startingAt: index) } label: {
                                HStack {
                                    Text(song.title ?? "Untitled")
                                    Spacer()
                                    Text(song.artist ?? "").foregroundStyle(Theme.secondaryText)
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.tempusPlain)
                            .contextMenu { SongMenu(songs: [song]) }
                        }
                    } label: {
                        HStack {
                            Text(group.title).font(.inter(.callout, weight: .medium))
                            Text("\(group.songs.count)").foregroundStyle(Theme.secondaryText)
                            Spacer()
                            Button("Play", tempus: .play) { session.player.play(group.songs) }
                                .labelStyle(.iconOnly).buttonStyle(.tempusBorderless)
                        }
                        .contextMenu {
                            Button("Play") { session.player.play(group.songs) }
                            Button("Remove Downloads", role: .destructive) {
                                Task { await downloads.delete(group.songs.map(\.id)) }
                            }
                        }
                    }
                }
            }
        }
        .toolbar {
            Picker("Group by", selection: $settings.downloadGrouping) {
                ForEach(DownloadGrouping.allCases) { Text($0.title).tag($0) }
            }
            Button("Remove All Downloads", tempus: .delete) { confirmsDeleteAll = true }
                .disabled(downloads.records.isEmpty)
        }
        .confirmationDialog("Remove all downloads for \(session.profile.name)?", isPresented: $confirmsDeleteAll) {
            Button("Remove All", role: .destructive) { Task { await downloads.deleteAll() } }
        }
    }

    @ViewBuilder private var status: some View {
        let downloads = session.downloads
        let pending = downloads.active.count + downloads.waiting.count
        HStack(spacing: Theme.Spacing.small) {
            Text(
                "\(downloads.records.count) tracks • \(ByteCountFormatter.string(fromByteCount: downloads.totalBytes, countStyle: .file))"
            )
            if pending > 0 {
                ProgressView().controlSize(.small)
                Text("Downloading \(pending)…")
                Button("Stop") { downloads.cancelAll() }.buttonStyle(.link)
            }
            if downloads.isHeldForNetwork {
                Text("Waiting for a network that isn't a hotspot or in Low Data Mode.")
            }
            Spacer()
            if let message = downloads.errorMessage {
                Text(message).foregroundStyle(Theme.error).lineLimit(1)
            }
        }
        .font(.inter(.caption))
        .foregroundStyle(Theme.secondaryText)
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.small)
    }

    /// Upstream's order: album artist, album, disc, track. No album artist sorts by album title.
    static func ordered(_ records: [DownloadRecord]) -> [DownloadRecord] {
        records.sorted { lhs, rhs in
            let left = (lhs.song.albumArtist ?? lhs.song.album ?? "", lhs.song.album ?? "")
            let right = (rhs.song.albumArtist ?? rhs.song.album ?? "", rhs.song.album ?? "")
            if left.0 != right.0 {
                return left.0.localizedStandardCompare(right.0) == .orderedAscending
            }
            if left.1 != right.1 {
                return left.1.localizedStandardCompare(right.1) == .orderedAscending
            }
            let leftTrack = (lhs.song.discNumber ?? 0, lhs.song.track ?? 0)
            let rightTrack = (rhs.song.discNumber ?? 0, rhs.song.track ?? 0)
            return leftTrack < rightTrack
        }
    }

    private func groups(_ grouping: DownloadGrouping) -> [Group] {
        let records = Self.ordered(session.downloads.downloads)
        let key: (DownloadRecord) -> String = switch grouping {
        case .track, .album: { $0.song.album ?? "Unknown album" }
        case .artist: { $0.song.albumArtist ?? $0.song.artist ?? "Unknown artist" }
        case .genre: { $0.song.genre ?? "Unknown genre" }
        case .playlist: { $0.playlistName ?? "Not from a playlist" }
        case .year: { $0.song.year.map(String.init) ?? "Unknown year" }
        }
        var order: [String] = []
        var songs: [String: [Song]] = [:]
        for record in records {
            let name = key(record)
            if songs[name] == nil {
                order.append(name)
            }
            songs[name, default: []].append(record.song)
        }
        let sortedNames = grouping == .year ? order.sorted(by: >) : order
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return sortedNames.map { Group(id: $0, title: $0, songs: songs[$0] ?? []) }
    }
}

// MARK: Shares

struct SharesView: View {
    @Environment(ServerSession.self) private var session
    @State private var revision = 0
    @State private var errorMessage: String?

    var body: some View {
        SnapshotView(request: .shares, reloadKey: revision) { shares in
            if shares.isEmpty {
                EmptyState(
                    art: .illustration(.share),
                    title: "No shares",
                    message: Text("Share an album, playlist or track from its menu.")
                )
            } else {
                List(shares) { share in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(share.description ?? share.entries.first?.album ?? "Share").font(.inter(
                            .callout,
                            weight: .medium
                        ))
                        Text(share.url?.absoluteString ?? "").font(.inter(.caption)).textSelection(.enabled)
                        Text([
                            "\(share.entries.count) items",
                            share.expires.map { "expires \($0.formatted(date: .abbreviated, time: .omitted))" },
                            share.visitCount.map { "\($0) visits" },
                        ].compactMap(\.self).joined(separator: " • "))
                            .font(.inter(.caption)).foregroundStyle(Theme.secondaryText)
                    }
                    .contextMenu {
                        if let url = share.url {
                            Button("Copy Link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                            }
                            if let web = RadioStationForm.webURL(url.absoluteString) {
                                Button("Open in Browser") { NSWorkspace.shared.open(web) }
                            }
                        }
                        Button("Play") { session.player.play(share.entries) }
                        Divider()
                        Button("Delete Share", role: .destructive) {
                            Task {
                                do throws(SubsonicError) {
                                    _ = try await session.client.send(.deleteShare(id: share.id))
                                    revision += 1
                                } catch {
                                    errorMessage = error.userMessage
                                }
                            }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let errorMessage {
                Text(errorMessage).font(.inter(.callout)).foregroundStyle(Theme.error).padding(Theme.Spacing.small)
            }
        }
        .toolbar { Button("Refresh", tempus: .refresh) { revision += 1 } }
    }
}

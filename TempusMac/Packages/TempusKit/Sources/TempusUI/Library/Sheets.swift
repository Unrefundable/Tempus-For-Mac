import AppCore
import AppKit
import DesignSystem
import SubsonicAPI
import SwiftUI

/// Shows whichever sheet `SheetPresenter` holds.
struct PresentedSheet: View {
    let sheet: SheetPresenter.Sheet

    @Environment(SheetPresenter.self) private var sheets

    var body: some View {
        Group {
            switch sheet {
            case let .addToPlaylist(songs): AddToPlaylistSheet(songs: songs)
            case let .newPlaylist(songs): NewPlaylistSheet(songs: songs)
            case let .trackInfo(song): TrackInfoSheet(song: song)
            case let .share(ids, name): ShareSheet(ids: ids, name: name)
            case let .message(title, text): MessageSheet(title: title, text: text)
            }
        }
        .padding(Theme.Spacing.xLarge)
    }
}

private struct SheetButtons: View {
    var confirm: String?
    var isBusy = false
    var canConfirm = true
    var action: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack {
            if isBusy {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button(confirm == nil ? "Done" : "Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            if let confirm, let action {
                Button(confirm, action: action)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm || isBusy)
            }
        }
    }
}

/// Upstream's "Add to playlist": pick one of yours, or make a new one with the songs in it.
struct AddToPlaylistSheet: View {
    let songs: [Song]

    @Environment(ServerSession.self) private var session
    @Environment(SheetPresenter.self) private var sheets
    @Environment(\.dismiss) private var dismiss
    @State private var playlists: [Playlist] = []
    @State private var errorMessage: String?
    @State private var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Add \(songs.count == 1 ? "“\(songs[0].title ?? "Track")”" : "\(songs.count) songs") to a Playlist")
                .font(.inter(.headline))
            List(playlists) { playlist in
                Button {
                    add(to: playlist)
                } label: {
                    HStack {
                        ArtworkView(
                            coverArtID: playlist.coverArtID,
                            size: .thumbnail,
                            cornerRadius: Theme.Radius.artworkSmall,
                            placeholder: .playlist
                        )
                        .frame(width: Theme.Size.trackCover, height: Theme.Size.trackCover)
                        Text(playlist.name ?? "Playlist")
                        Spacer()
                        Text("\(playlist.songCount ?? 0)").foregroundStyle(.secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 240)
            if let errorMessage {
                Text(errorMessage).font(.inter(.callout)).foregroundStyle(.red)
            }
            HStack {
                Button("New Playlist…") { sheets.present(.newPlaylist(songs)) }
                Spacer()
                SheetButtons(isBusy: isBusy)
            }
        }
        .frame(width: 400)
        .task {
            do throws(SubsonicError) {
                let all = try await session.client.send(.playlists)
                let faves = await session.playlists.faves()
                playlists = session.settings.playlistSort.sorted(all, faves: faves)
            } catch {
                errorMessage = error.userMessage
            }
        }
    }

    private func add(to playlist: Playlist) {
        isBusy = true
        Task {
            defer { isBusy = false }
            do throws(PlaylistEditError) {
                try await session.playlists.add(songs, to: playlist)
                dismiss()
            } catch {
                errorMessage = error.message
            }
        }
    }
}

struct NewPlaylistSheet: View {
    let songs: [Song]

    @Environment(ServerSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var errorMessage: String?
    @State private var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("New Playlist").font(.inter(.headline))
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).onSubmit(create)
            if !songs.isEmpty {
                Text("With \(songs.count) \(songs.count == 1 ? "song" : "songs")").font(.inter(.callout))
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage).font(.inter(.callout)).foregroundStyle(.red)
            }
            SheetButtons(
                confirm: "Create",
                isBusy: isBusy,
                canConfirm: !name.trimmingCharacters(in: .whitespaces).isEmpty,
                action: create
            )
        }
        .frame(width: 360)
    }

    private func create() {
        guard !isBusy else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do throws(PlaylistEditError) {
                try await session.playlists.create(name: name, songs: songs)
                dismiss()
            } catch {
                errorMessage = error.message
            }
        }
    }
}

/// Upstream's track info dialog.
struct TrackInfoSheet: View {
    let song: Song

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack(spacing: Theme.Spacing.medium) {
                ArtworkView(coverArtID: song.coverArtID, size: .medium, placeholder: .song)
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading) {
                    Text(song.title ?? "Untitled").font(.inter(.headline))
                    Text(song.artist ?? "").foregroundStyle(.secondary)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.large, verticalSpacing: Theme.Spacing.xSmall) {
                ForEach(Self.fields(of: song), id: \.0) { field in
                    GridRow {
                        Text(field.0).foregroundStyle(.secondary)
                        Text(field.1).textSelection(.enabled)
                    }
                }
            }
            .font(.inter(.callout))
            SheetButtons()
        }
        .frame(width: 440)
    }

    static func fields(of song: Song) -> [(String, String)] {
        let rows: [(String, String?)] = [
            ("Album", song.album),
            ("Album artist", song.albumArtist),
            ("Track", song.track.map { track in (song.discNumber.map { "\($0)-" } ?? "") + String(track) }),
            ("Year", song.year.map(String.init)),
            ("Genre", song.genre),
            ("Length", song.duration.map { TrackFormatting.time(TimeInterval($0)) }),
            ("Format", TrackFormatting.quality(of: song)),
            ("Size", song.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }),
            ("Plays", song.playCount.map(String.init)),
            ("Rating", song.userRating.map { String(repeating: "★", count: $0) }),
            ("Path", song.path),
        ]
        return rows.compactMap { name, value in value.flatMap { $0.isEmpty ? nil : (name, $0) } }
    }
}

/// Creates a share link on the server and copies it.
struct ShareSheet: View {
    let ids: [String]
    let name: String

    @Environment(ServerSession.self) private var session
    @State private var note = ""
    @State private var expires = false
    @State private var expiry = Date.now.addingTimeInterval(7 * 24 * 3600)
    @State private var link: URL?
    @State private var errorMessage: String?
    @State private var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Share “\(name)”").font(.inter(.headline))
            if let link {
                HStack {
                    Text(link.absoluteString).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Button("Copy") { copy(link) }
                }
                Text("The link was copied.").font(.inter(.callout)).foregroundStyle(.secondary)
                SheetButtons()
            } else {
                TextField("Description (optional)", text: $note).textFieldStyle(.roundedBorder)
                Toggle("Expires", isOn: $expires)
                if expires {
                    DatePicker("On", selection: $expiry, in: Date.now..., displayedComponents: .date)
                }
                if let errorMessage {
                    Text(errorMessage).font(.inter(.callout)).foregroundStyle(.red)
                }
                SheetButtons(confirm: "Create Link", isBusy: isBusy, action: create)
            }
        }
        .frame(width: 400)
    }

    private func create() {
        isBusy = true
        Task {
            defer { isBusy = false }
            do throws(SubsonicError) {
                let shares = try await session.client.send(.createShare(
                    ids: ids, description: note.isEmpty ? nil : note, expires: expires ? expiry : nil
                ))
                guard let url = shares.first?.url else {
                    errorMessage = "The server didn't return a link."
                    return
                }
                link = url
                copy(url)
            } catch {
                errorMessage = error.userMessage
            }
        }
    }

    private func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}

private struct MessageSheet: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text(title).font(.inter(.headline))
            Text(text)
            SheetButtons()
        }
        .frame(width: 360)
    }
}

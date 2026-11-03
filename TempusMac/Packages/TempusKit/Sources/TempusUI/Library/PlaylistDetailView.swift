import AppCore
import DesignSystem
import SubsonicAPI
import SwiftUI

/// A playlist: its tracks, Edit (rename, reorder, remove), Keep Synced, faves, delete.
struct PlaylistDetailView: View {
    let playlistID: String

    @Environment(ServerSession.self) private var session
    @Environment(Navigator.self) private var navigator
    @Environment(SheetPresenter.self) private var sheets
    @State private var revision = 0
    @State private var editing: Playlist?
    @State private var isFave = false
    @State private var errorMessage: String?
    @State private var confirmsDelete: Playlist?

    var body: some View {
        SnapshotView(request: .playlist(id: playlistID), reloadKey: revision) { playlist in
            VStack(spacing: 0) {
                DetailHeader(
                    coverArtID: playlist.coverArtID,
                    kind: "Playlist",
                    title: playlist.name ?? "Playlist",
                    subtitle: playlist.comment,
                    detail: TrackFormatting.queueSummary(playlist.entries)
                        + (session.downloads.isKeptSynced(playlist.id) ? " • Kept synced" : "")
                ) {
                    PlayButtons { playlist.entries }
                    Button("Edit", systemImage: "pencil") { Task { await beginEditing() } }
                    Menu("More", tempus: .moreVert) { menu(for: playlist) }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                }
                if let errorMessage {
                    Text(errorMessage).font(.inter(.callout)).foregroundStyle(.red).padding(
                        .bottom,
                        Theme.Spacing.small
                    )
                }
                TrackTable(
                    songs: playlist.entries,
                    source: .init(playlistID: playlist.id, playlistName: playlist.name ?? "Playlist")
                )
                .dropDestination(for: SongTransfer.self) { items, _ in
                    let songs = items.flatMap(\.songs)
                    Task {
                        try? await session.playlists.add(songs, to: playlist)
                        revision += 1
                    }
                    return !songs.isEmpty
                }
            }
            .task(id: playlist.id) {
                isFave = await session.playlists.faves().contains(playlist.id)
                if let synced = session.downloads.syncedPlaylists.first(where: { $0.id == playlist.id }) {
                    await session.downloads.sync(synced) // upstream checks again each time it's opened
                }
            }
        }
        .sheet(item: $editing) { playlist in
            PlaylistEditor(playlist: playlist) { revision += 1 }
        }
        .confirmationDialog(
            "Delete “\(confirmsDelete?.name ?? "")” from the server?",
            isPresented: Binding(
                get: { confirmsDelete != nil },
                set: {
                    if !$0 {
                        confirmsDelete = nil
                    }
                }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let playlist = confirmsDelete {
                    delete(playlist)
                }
            }
        }
        .navigationTitle("Playlist")
    }

    @ViewBuilder private func menu(for playlist: Playlist) -> some View {
        Toggle("Keep Synced", isOn: Binding(
            get: { session.downloads.isKeptSynced(playlist.id) },
            set: { keeps in Task { await session.downloads.setKeepsSynced(keeps, playlist: playlist) } }
        ))
        Button("Download All") {
            session.downloads.download(
                playlist.entries,
                from: .init(playlistID: playlist.id, playlistName: playlist.name ?? "")
            )
        }
        Button(isFave ? "Remove from Faves" : "Add to Faves") {
            Task {
                await session.playlists.setFave(!isFave, playlistID: playlist.id)
                isFave.toggle()
            }
        }
        if session.features.hasShares {
            Button("Share…") { sheets.present(.share(ids: [playlist.id], name: playlist.name ?? "Playlist")) }
        }
        Divider()
        Button("Delete Playlist…", role: .destructive) { confirmsDelete = playlist }
    }

    private func delete(_ playlist: Playlist) {
        Task {
            do throws(PlaylistEditError) {
                try await session.playlists.delete(playlist)
                await session.downloads.setKeepsSynced(false, playlist: playlist)
                navigator.path.removeLast(min(1, navigator.path.count))
            } catch {
                errorMessage = error.message
            }
        }
    }

    /// Editing needs the server's current list, never the offline copy (upstream).
    private func beginEditing() async {
        errorMessage = nil
        do throws(SubsonicError) {
            editing = try await session.client.send(.playlist(id: playlistID))
        } catch {
            errorMessage = "Editing needs the server: \(error.userMessage)"
        }
    }
}

/// Rename, reorder and remove; Save writes the list exactly as shown.
private struct PlaylistEditor: View {
    let playlist: Playlist
    let onSave: () -> Void

    @Environment(ServerSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var entries: [Entry] = []
    @State private var errorMessage: String?
    @State private var isSaving = false

    private struct Entry: Identifiable {
        let id = UUID()
        let song: Song
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Edit Playlist").font(.inter(.headline))
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            List {
                ForEach(entries) { entry in
                    HStack {
                        TempusIconImage(.dragHandle).foregroundStyle(.tertiary)
                        VStack(alignment: .leading) {
                            Text(entry.song.title ?? "Untitled")
                            Text(entry.song.artist ?? "").font(.inter(.caption)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", systemImage: "minus.circle.fill") {
                            entries.removeAll { $0.id == entry.id }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                    }
                }
                .onMove { entries.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { entries.remove(atOffsets: $0) }
            }
            .frame(minHeight: 320)
            if let errorMessage {
                Text(errorMessage).font(.inter(.callout)).foregroundStyle(.red)
            }
            HStack {
                if isSaving {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(isSaving)
            }
        }
        .padding(Theme.Spacing.xLarge)
        .frame(width: 480)
        .onAppear {
            name = playlist.name ?? ""
            entries = playlist.entries.map { Entry(song: $0) }
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do throws(PlaylistEditError) {
                // The server's count now, in case another client changed it while editing.
                let current: Playlist
                do throws(SubsonicError) {
                    current = try await session.client.send(.playlist(id: playlist.id))
                } catch {
                    throw .server(error)
                }
                try await session.playlists.save(
                    playlistID: playlist.id, name: name, serverCount: current.entries.count, songs: entries.map(\.song)
                )
                onSave()
                dismiss()
            } catch {
                errorMessage = error.message
            }
        }
    }
}

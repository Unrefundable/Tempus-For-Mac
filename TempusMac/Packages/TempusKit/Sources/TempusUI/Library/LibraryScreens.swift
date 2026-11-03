import AppCore
import DesignSystem
import Library
import SubsonicAPI
import SwiftUI

/// Every album, sorted as chosen, loaded a page at a time.
struct AlbumsView: View {
    static let pageSize = 60

    @Environment(ServerSession.self) private var session
    @State private var albums: [Album] = []
    @State private var isLoading = false
    @State private var reachedEnd = false
    @State private var errorMessage: String?

    var body: some View {
        @Bindable var settings = session.settings
        ScrollView {
            AlbumGrid(albums: albums) { Task { await loadMore() } }
            if isLoading {
                ProgressView().padding()
            } else if albums.isEmpty, let errorMessage {
                EmptyState(art: .icon(.albums), title: "Couldn't load albums", message: Text(errorMessage))
            } else if albums.isEmpty, reachedEnd {
                EmptyState(art: .icon(.albums), title: "No albums")
            }
        }
        .toolbar {
            Picker("Sort", selection: $settings.albumSort) {
                ForEach(AlbumSort.allCases) { Text($0.title).tag($0) }
            }
            .help("Sort albums")
        }
        .task(id: [AnyHashable(settings.albumSort), AnyHashable(session.musicFolderID)]) {
            await reload()
        }
    }

    private func request(offset: Int) -> SubsonicRequest<[Album]> {
        .albumList(
            session.settings.albumSort.listType,
            size: Self.pageSize,
            offset: offset,
            musicFolderID: session.musicFolderID
        )
    }

    /// The first page cache-first, so the grid draws at once.
    private func reload() async {
        albums = []
        reachedEnd = false
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        do {
            for try await snapshot in session.library.snapshots(request(offset: 0)) {
                albums = snapshot.value
                reachedEnd = snapshot.value.count < Self.pageSize
            }
        } catch let error as SubsonicError {
            errorMessage = error.userMessage
        } catch {}
    }

    private func loadMore() async {
        guard !isLoading, !reachedEnd, !albums.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        let asked = request(offset: albums.count)
        do throws(SubsonicError) {
            let page = try await session.library.refresh(asked)
            // The sort or library changed meanwhile: this page belongs to the old list.
            guard asked.cacheKey == request(offset: albums.count).cacheKey else { return }
            let known = Set(albums.map(\.id))
            albums += page.filter { !known.contains($0.id) }
            reachedEnd = page.count < Self.pageSize
        } catch {
            errorMessage = error.userMessage // scrolling to the end again retries
        }
    }
}

/// Artists by index letter (`getArtists`).
struct ArtistsView: View {
    @Environment(ServerSession.self) private var session
    @Environment(Navigator.self) private var navigator

    var body: some View {
        SnapshotView(
            request: .artists(musicFolderID: session.musicFolderID),
            reloadKey: session.musicFolderID
        ) { indexes in
            if indexes.indexes.isEmpty {
                EmptyState(art: .icon(.artists), title: "No artists")
            } else {
                List {
                    ForEach(indexes.indexes, id: \.name) { index in
                        Section(index.name ?? "#") {
                            ForEach(index.artists) { artist in
                                Button { navigator.open(.artist(id: artist.id)) } label: { ArtistRow(artist: artist) }
                                    .buttonStyle(.plain)
                                    .contextMenu { ArtistMenu(artist: artist) }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct ArtistRow: View {
    let artist: Artist

    @Environment(ServerSession.self) private var session

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            ArtworkView(
                coverArtID: artist.coverArtID,
                size: .thumbnail,
                cornerRadius: Theme.Size.trackCover / 2,
                placeholder: .artist
            )
            .frame(width: Theme.Size.trackCover, height: Theme.Size.trackCover)
            Text(artist.name ?? "Unknown artist")
            if session.stars.isStarred(artist) {
                TempusIconImage(.favorite).tempusIconSize(Theme.Size.badgeIcon).foregroundStyle(Theme.accent)
            }
            Spacer()
            if let count = artist.albumCount {
                Text("\(count) \(count == 1 ? "album" : "albums")").font(.inter(.caption)).foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
    }
}

struct GenresView: View {
    @Environment(Navigator.self) private var navigator

    var body: some View {
        SnapshotView(request: .genres) { genres in
            let sorted = genres.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if sorted.isEmpty {
                EmptyState(art: .icon(.genres), title: "No genres")
            } else {
                List(sorted, id: \.name) { genre in
                    Button { navigator.open(.genre(genre.name)) } label: {
                        HStack {
                            Text(genre.name)
                            Spacer()
                            Text("\(genre.albumCount ?? 0) albums • \(genre.songCount ?? 0) songs")
                                .font(.inter(.caption)).foregroundStyle(.secondary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Every playlist, in the chosen sort, with faves and New Playlist.
struct PlaylistsView: View {
    @Environment(ServerSession.self) private var session
    @Environment(Navigator.self) private var navigator
    @Environment(SheetPresenter.self) private var sheets
    @State private var faves: Set<String> = []
    @State private var revision = 0
    @State private var deleting: Playlist?

    var body: some View {
        @Bindable var settings = session.settings
        SnapshotView(request: .playlists, reloadKey: revision) { playlists in
            let sorted = settings.playlistSort.sorted(playlists, faves: faves)
            if sorted.isEmpty {
                ContentUnavailableView {
                    Label("No playlists", tempus: .playlist)
                } actions: {
                    Button("New Playlist…") { sheets.present(.newPlaylist([])) }
                }
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: Theme.Size.tile), spacing: Theme.Spacing.large)],
                        spacing: Theme.Spacing.xLarge
                    ) {
                        ForEach(sorted) { playlist in
                            Button { navigator.open(.playlist(id: playlist.id)) } label: {
                                CoverTile(
                                    coverArtID: playlist.coverArtID,
                                    title: playlist.name ?? "Playlist",
                                    subtitle: "\(playlist.songCount ?? 0) songs" +
                                        (faves.contains(playlist.id) ? " • ♥︎" : ""),
                                    placeholder: .playlist
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu { menu(for: playlist) }
                            .dropDestination(for: SongTransfer.self) { items, _ in
                                let songs = items.flatMap(\.songs)
                                Task {
                                    do throws(PlaylistEditError) {
                                        try await session.playlists.add(songs, to: playlist)
                                        revision += 1
                                    } catch {
                                        sheets.present(.message(
                                            title: playlist.name ?? "Playlist",
                                            text: error.message
                                        ))
                                    }
                                }
                                return !songs.isEmpty
                            }
                        }
                    }
                    .padding(Theme.Spacing.xLarge)
                }
            }
        }
        .task { faves = await session.playlists.faves() }
        .toolbar {
            Picker("Sort", selection: $settings.playlistSort) {
                ForEach(PlaylistSort.allCases) { Text($0.title).tag($0) }
            }
            Button("New Playlist", tempus: .add) { sheets.present(.newPlaylist([])) }
            Button("Refresh", tempus: .refresh) { revision += 1 }
        }
        .onChange(of: sheets.current == nil) {
            _, closed in if closed {
                revision += 1
            }
        }
        .confirmationDialog(
            "Delete “\(deleting?.name ?? "")” from the server?",
            isPresented: Binding(get: { deleting != nil }, set: {
                if !$0 {
                    deleting = nil
                }
            })
        ) {
            Button("Delete", role: .destructive) {
                guard let playlist = deleting else { return }
                Task {
                    do throws(PlaylistEditError) {
                        try await session.playlists.delete(playlist)
                        await session.downloads.setKeepsSynced(false, playlist: playlist)
                        revision += 1
                    } catch {
                        sheets.present(.message(title: playlist.name ?? "Playlist", text: error.message))
                    }
                }
            }
        }
    }

    @ViewBuilder private func menu(for playlist: Playlist) -> some View {
        Button("Play") { play(playlist, shuffled: false) }
        Button("Shuffle") { play(playlist, shuffled: true) }
        Divider()
        let isFave = faves.contains(playlist.id)
        Button(isFave ? "Remove from Faves" : "Add to Faves") {
            Task {
                await session.playlists.setFave(!isFave, playlistID: playlist.id)
                faves = await session.playlists.faves()
            }
        }
        Button("Delete Playlist…", role: .destructive) { deleting = playlist }
    }

    private func play(_ playlist: Playlist, shuffled: Bool) {
        Task {
            guard let songs = try? await session.client.send(.playlist(id: playlist.id)).entries,
                  !songs.isEmpty else { return }
            shuffled ? session.player.playShuffled(songs) : session.player.play(songs)
        }
    }
}

/// Upstream's Music folders: the folder index of the library in use.
struct FoldersView: View {
    @Environment(ServerSession.self) private var session
    @Environment(Navigator.self) private var navigator

    var body: some View {
        SnapshotView(
            request: .indexes(musicFolderID: session.musicFolderID),
            reloadKey: session.musicFolderID
        ) { root in
            List {
                if !root.children.isEmpty {
                    Section("Files") { TrackTable(songs: root.children).frame(minHeight: 200) }
                }
                ForEach(root.indexes, id: \.name) { index in
                    Section(index.name ?? "#") {
                        ForEach(index.artists) { entry in
                            Button { navigator.open(.folder(id: entry.id, name: entry.name ?? "Folder")) } label: {
                                Label(entry.name ?? "Folder", tempus: .folder).contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

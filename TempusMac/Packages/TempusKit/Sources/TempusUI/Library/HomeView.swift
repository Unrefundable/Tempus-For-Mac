import AppCore
import DesignSystem
import Persistence
import SubsonicAPI
import SwiftUI

/// Upstream's Music tab: the sections chosen in Settings, in their order. Empty ones hide.
struct HomeView: View {
    @Environment(ServerSession.self) private var session
    @State private var revision = 0

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.large) {
                ForEach(session.settings.homeLayout.visible) { section in
                    HomeSectionView(section: section)
                }
            }
            .padding(.vertical, Theme.Spacing.xLarge)
            .id(revision)
        }
        .toolbar {
            Button("Refresh", tempus: .refresh) { revision += 1 }
                .help("Reload Home")
        }
        .overlay {
            if session.settings.homeLayout.visible.isEmpty {
                EmptyState(
                    art: .icon(.home),
                    title: "Home is empty",
                    message: Text("Turn sections on in Settings › Home.")
                )
            }
        }
    }
}

/// Loads one section; draws nothing while empty, as upstream hides empty rows.
private struct HomeSectionView: View {
    let section: HomeSection

    @Environment(ServerSession.self) private var session
    @Environment(Navigator.self) private var navigator

    var body: some View {
        switch section {
        case .continueListening: ContinueListeningRow()
        case .discover:
            CachedRow(request: .randomSongs(size: 20, musicFolderID: session.musicFolderID)) { songs in
                SongRow(title: section.title, songs: songs)
            }
        case .recentlyPlayed:
            LocalSongsRow(title: section.title) { try await session.history.recentlyPlayed(
                server: session.profile.id,
                limit: 20
            ) }
        case .thisWeek:
            LocalSongsRow(title: section.title) {
                try await session.history.mostPlayed(
                    server: session.profile.id, from: .now.addingTimeInterval(-7 * 24 * 3600), to: .now, limit: 20
                )
            }
        case .recentlyAdded: albums(.newest)
        case .mostPlayed: albums(.frequent)
        case .recentAlbums: albums(.recent)
        case .topRated: albums(.highest)
        case .randomAlbums: albums(.random)
        case .flashback:
            let decade = Self.flashbackDecade(now: .now)
            CachedRow(request: .albumList(
                .byYear(from: decade, to: decade + 9),
                size: 20,
                musicFolderID: session.musicFolderID
            )) {
                if !$0.isEmpty {
                    CoverRow(title: "Flashback: the \(decade)s", items: $0) { AlbumTile(album: $0) }
                }
            }
        case .starredTracks:
            CachedRow(request: .starred(musicFolderID: session.musicFolderID), reloadsOnStar: true) {
                SongRow(title: section.title, songs: $0.songs)
            }
        case .starredAlbums:
            CachedRow(request: .starred(musicFolderID: session.musicFolderID), reloadsOnStar: true) {
                if !$0.albums.isEmpty {
                    CoverRow(title: section.title, items: $0.albums) { AlbumTile(album: $0) }
                }
            }
        case .starredArtists:
            CachedRow(request: .starred(musicFolderID: session.musicFolderID), reloadsOnStar: true) {
                if !$0.artists.isEmpty {
                    CoverRow(title: section.title, items: $0.artists) { ArtistTile(artist: $0) }
                }
            }
        case .pinnedPlaylists: PlaylistRow(title: section.title, onlyFaves: true)
        case .playlists: PlaylistRow(title: section.title, onlyFaves: false)
        case .genres: GenreChips()
        case .newestPodcasts:
            if session.features.hasPodcasts {
                CachedRow(request: .newestPodcasts(count: 15)) { episodes in
                    SongRow(title: section.title, songs: episodes.compactMap { $0.song(channelTitle: nil) })
                }
            }
        }
    }

    private func albums(_ type: AlbumListType) -> some View {
        CachedRow(request: .albumList(type, size: 20, musicFolderID: session.musicFolderID)) { albums in
            if !albums.isEmpty {
                CoverRow(title: section.title, items: albums, seeAll: seeAll(type)) { AlbumTile(album: $0) }
            }
        }
    }

    private func seeAll(_ type: AlbumListType) -> (() -> Void)? {
        let sort: AlbumSort? = switch type {
        case .newest: .newest
        case .frequent: .frequent
        case .recent: .recent
        case .highest: .highest
        case .random: .random
        default: nil
        }
        guard let sort else { return nil }
        return {
            session.settings.albumSort = sort
            navigator.selection = .albums
        }
    }

    /// A decade from the 1960s to the last full one, changing each week.
    static func flashbackDecade(now: Date) -> Int {
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: now)
        let decades = Array(stride(from: 1960, through: (year / 10 - 1) * 10, by: 10))
        let week = calendar.component(.weekOfYear, from: now) + year * 53
        return decades[week % decades.count]
    }
}

/// A request's value, cache-first; nothing at all if it fails with nothing cached.
private struct CachedRow<Value: Decodable & Sendable, Content: View>: View {
    let request: SubsonicRequest<Value>
    /// Starred rows reload in place after a star changes.
    var reloadsOnStar = false
    @ViewBuilder let content: (Value) -> Content

    @Environment(ServerSession.self) private var session
    @State private var value: Value?

    var body: some View {
        // A task on an empty view never starts, so there is always something to hang it on.
        VStack(spacing: 0) {
            if let value {
                content(value)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 1, alignment: .leading)
        .task(id: [AnyHashable(request.cacheKey), AnyHashable(reloadsOnStar ? session.stars.revision : 0)]) {
            do {
                for try await snapshot in session.library.snapshots(request) {
                    value = snapshot.value
                }
            } catch {}
        }
    }
}

private struct LocalSongsRow: View {
    let title: String
    let load: @MainActor () async throws -> [Song]

    @State private var songs: [Song] = []

    var body: some View {
        VStack(spacing: 0) {
            SongRow(title: title, songs: songs)
        }
        .frame(maxWidth: .infinity, minHeight: 1, alignment: .leading)
        .task { songs = await (try? load()) ?? [] }
    }
}

/// Songs as cover tiles; a click plays the row from that song.
struct SongRow: View {
    let title: String
    let songs: [Song]

    @Environment(ServerSession.self) private var session

    private struct Item: Identifiable {
        let id: Int
        let song: Song
    }

    var body: some View {
        if !songs.isEmpty {
            CoverRow(title: title, items: songs.enumerated().map { Item(id: $0.offset, song: $0.element) }) { item in
                Button { session.player.play(songs, startingAt: item.id) } label: {
                    CoverTile(
                        coverArtID: item.song.coverArtID,
                        title: item.song.title ?? "Untitled",
                        subtitle: item.song.artist,
                        placeholder: .song
                    )
                }
                .buttonStyle(.tempusPlain)
                .contextMenu { SongMenu(songs: [item.song]) }
                .draggable(SongTransfer(songs: [item.song]))
            }
        }
    }
}

/// Upstream's Continue Listening: bookmarked tracks, newest first, each with its resume time.
private struct ContinueListeningRow: View {
    @Environment(ServerSession.self) private var session
    @State private var bookmarks: [Bookmark] = []

    private struct Item: Identifiable {
        let id: String
        let bookmark: Bookmark
    }

    var body: some View {
        VStack(spacing: 0) {
            if !bookmarks.isEmpty {
                CoverRow(
                    title: "Continue Listening",
                    items: bookmarks.map { Item(id: $0.entry.id, bookmark: $0) }
                ) { item in
                    Button { resume(item.bookmark) } label: {
                        CoverTile(
                            coverArtID: item.bookmark.entry.coverArtID,
                            title: item.bookmark.entry.title ?? "Untitled",
                            subtitle: "Resume at \(TrackFormatting.time(TimeInterval(item.bookmark.position) / 1000))",
                            placeholder: .song
                        )
                    }
                    .buttonStyle(.tempusPlain)
                    .contextMenu {
                        Button("Remove from Continue Listening") {
                            Task {
                                _ = try? await session.client.send(.deleteBookmark(id: item.id))
                                bookmarks.removeAll { $0.entry.id == item.id }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 1, alignment: .leading)
        .task {
            let all = await (try? session.client.send(.bookmarks)) ?? []
            bookmarks = all.sorted { ($0.changed ?? .distantPast) > ($1.changed ?? .distantPast) }
        }
    }

    /// Plays from the saved spot, with the rest of its album after it.
    private func resume(_ bookmark: Bookmark) {
        Task {
            let (songs, index) = await session.sources.resumeQueue(for: bookmark)
            session.player.play(songs, startingAt: index)
            session.player.seek(to: TimeInterval(bookmark.position) / 1000)
        }
    }
}

private struct PlaylistRow: View {
    let title: String
    let onlyFaves: Bool

    @Environment(ServerSession.self) private var session
    @Environment(Navigator.self) private var navigator
    @State private var faves: Set<String> = []

    var body: some View {
        CachedRow(request: .playlists) { playlists in
            let sorted = session.settings.playlistSort.sorted(playlists, faves: faves)
            let shown = Array((onlyFaves ? sorted.filter { faves.contains($0.id) } : sorted).prefix(20))
            if !shown.isEmpty {
                CoverRow(
                    title: title,
                    items: shown,
                    seeAll: onlyFaves ? nil : { navigator.selection = .playlists }
                ) { playlist in
                    Button { navigator.open(.playlist(id: playlist.id)) } label: {
                        CoverTile(
                            coverArtID: playlist.coverArtID,
                            title: playlist.name ?? "Playlist",
                            subtitle: "\(playlist.songCount ?? 0) songs",
                            placeholder: .playlist
                        )
                    }
                    .buttonStyle(.tempusPlain)
                }
            }
        }
        .task { faves = await session.playlists.faves() }
    }
}

private struct GenreChips: View {
    @Environment(Navigator.self) private var navigator

    var body: some View {
        CachedRow(request: .genres) { genres in
            let top = genres.sorted { ($0.songCount ?? 0) > ($1.songCount ?? 0) }.prefix(20)
            if !top.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    Text("Genres").font(.inter(.title2, weight: .bold)).padding(.horizontal, Theme.Spacing.xLarge)
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(Array(top), id: \.name) { genre in
                                Button(genre.name) { navigator.open(.genre(genre.name)) }
                                    .buttonStyle(.bordered)
                                    .buttonBorderShape(.capsule)
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.xLarge)
                    }
                    .scrollIndicators(.never)
                }
            }
        }
    }
}

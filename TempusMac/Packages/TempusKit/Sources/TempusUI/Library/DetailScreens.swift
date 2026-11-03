import AppCore
import DesignSystem
import SubsonicAPI
import SwiftUI

struct AlbumDetailView: View {
    let albumID: String

    @Environment(ServerSession.self) private var session
    @Environment(Navigator.self) private var navigator
    @Environment(SheetPresenter.self) private var sheets

    var body: some View {
        SnapshotView(request: .album(id: albumID)) { album in
            VStack(spacing: 0) {
                DetailHeader(
                    coverArtID: album.coverArtID,
                    kind: album.isCompilation == true ? "Compilation" : "Album",
                    title: album.name ?? "Untitled",
                    subtitle: album.displayArtist ?? album.artist,
                    detail: Self.detail(album)
                ) {
                    PlayButtons { album.songs }
                    Button(
                        session.stars.isStarred(album) ? "Starred" : "Star",
                        tempus: session.stars.isStarred(album) ? .favorite : .favoritesOutlined
                    ) {
                        Task { await session.stars.toggle(album) }
                    }
                    Menu("More", tempus: .moreVert) {
                        AlbumMenu(album: album)
                        if let artistID = album.artistID {
                            Divider()
                            Button("Go to Artist") { navigator.open(.artist(id: artistID)) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                TrackTable(songs: album.songs)
            }
        }
        .navigationTitle("Album")
    }

    static func detail(_ album: Album) -> String {
        var parts: [String] = []
        if let year = album.year {
            parts.append(String(year))
        }
        if let genre = album.genre {
            parts.append(genre)
        }
        parts.append(TrackFormatting.queueSummary(album.songs))
        return parts.joined(separator: " • ")
    }
}

struct ArtistDetailView: View {
    let artistID: String

    @Environment(ServerSession.self) private var session
    @State private var info: ArtistInfo?
    @State private var topSongs: [Song] = []

    var body: some View {
        SnapshotView(request: .artist(id: artistID)) { artist in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
                    DetailHeader(
                        coverArtID: artist.coverArtID,
                        kind: "Artist",
                        title: artist.name ?? "Unknown artist",
                        subtitle: artist.albumCount.map { "\($0) albums" },
                        detail: nil,
                        round: true
                    ) {
                        PlayButtons { try await session.sources.songs(ofArtist: artist.id) }
                        Button("Radio", tempus: .feed) {
                            Task {
                                if let mix = try? await session.sources.artistMix(artist), !mix.isEmpty {
                                    session.player.play(mix)
                                }
                            }
                        }
                        Button(
                            session.stars.isStarred(artist) ? "Starred" : "Star",
                            tempus: session.stars.isStarred(artist) ? .favorite : .favoritesOutlined
                        ) {
                            Task { await session.stars.toggle(artist) }
                        }
                    }
                    if let biography = info?.biography.map(Self.plainText), !biography.isEmpty {
                        Text(biography)
                            .font(.inter(.callout))
                            .foregroundStyle(.secondary)
                            .lineLimit(6)
                            .textSelection(.enabled)
                            .padding(.horizontal, Theme.Spacing.xLarge)
                    }
                    if !topSongs.isEmpty {
                        Text("Top Songs").font(.inter(.title2, weight: .bold)).padding(
                            .horizontal,
                            Theme.Spacing.xLarge
                        )
                        TrackTable(songs: topSongs)
                            .frame(height: CGFloat(min(topSongs.count, 10)) * Theme.Size.tableRow + Theme.Size
                                .tableHeader)
                            .padding(.horizontal, Theme.Spacing.large)
                    }
                    if !artist.albums.isEmpty {
                        Text("Albums").font(.inter(.title2, weight: .bold)).padding(.horizontal, Theme.Spacing.xLarge)
                        AlbumGrid(albums: artist.albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) })
                    }
                    if !artist.appearsOn.isEmpty {
                        CoverRow(title: "Appears On", items: artist.appearsOn) { AlbumTile(album: $0) }
                    }
                    if let similar = info?.similarArtists, !similar.isEmpty {
                        CoverRow(title: "Similar Artists", items: similar) { ArtistTile(artist: $0) }
                    }
                }
                .padding(.bottom, Theme.Spacing.xLarge)
            }
            .task(id: artist.id) {
                info = try? await session.client.send(.artistInfo(id: artist.id))
                if let name = artist.name {
                    topSongs = await Array(((try? session.client.send(.topSongs(artist: name, count: 10))) ?? [])
                        .prefix(10))
                }
            }
        }
        .navigationTitle("Artist")
    }

    /// Last.fm biographies carry a trailing HTML link.
    static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct GenreDetailView: View {
    let genre: String

    @Environment(ServerSession.self) private var session

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                HStack {
                    Text(genre).font(.inter(.largeTitle, weight: .bold))
                    Spacer()
                    PlayButtons {
                        try await session.client.send(.songsByGenre(
                            genre,
                            count: 200,
                            musicFolderID: session.musicFolderID
                        ))
                    }
                }
                .padding([.horizontal, .top], Theme.Spacing.xLarge)
                SnapshotView(request: .albumList(
                    .byGenre(genre),
                    size: 120,
                    musicFolderID: session.musicFolderID
                )) { albums in
                    AlbumGrid(albums: albums)
                }
                .frame(minHeight: 300)
            }
        }
        .navigationTitle(genre)
    }
}

struct FolderDetailView: View {
    let folderID: String
    let name: String

    @Environment(ServerSession.self) private var session
    @Environment(Navigator.self) private var navigator

    var body: some View {
        SnapshotView(request: .musicDirectory(id: folderID)) { directory in
            let folders = directory.children.filter { $0.isDir == true }
            let tracks = directory.children.filter { $0.isDir != true && $0.isVideo != true }
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label(directory.name ?? name, tempus: .folder)
                        .font(.inter(.title, weight: .bold))
                        .tempusIconSize(Theme.Size.titleIcon)
                    Spacer()
                    // Upstream: inner folders play every track inside, subfolders included.
                    PlayButtons { try await session.sources.songs(inFolder: folderID) }
                }
                .padding(Theme.Spacing.xLarge)
                if !folders.isEmpty {
                    List(folders) { folder in
                        Button { navigator.open(.folder(id: folder.id, name: folder.title ?? "Folder")) } label: {
                            HStack {
                                ArtworkView(
                                    coverArtID: folder.coverArtID,
                                    size: .thumbnail,
                                    cornerRadius: Theme.Radius.artworkSmall,
                                    placeholder: .folder
                                )
                                .frame(width: Theme.Size.trackCover, height: Theme.Size.trackCover)
                                Text(folder.title ?? "Folder")
                                Spacer()
                                TempusIconImage(.navigateNext).foregroundStyle(.tertiary)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(minHeight: tracks.isEmpty ? 300 : 160, maxHeight: tracks.isEmpty ? .infinity : 260)
                }
                if !tracks.isEmpty {
                    TrackTable(songs: tracks)
                }
            }
        }
        .navigationTitle(name)
    }
}

import AppCore
import SubsonicAPI
import SwiftUI

// MARK: Context menus

/// What every list offers for songs: play, queue, mix, playlist, star, download, go to, share.
struct SongMenu: View {
    let songs: [Song]
    var source: DownloadManager.Source?

    @Environment(ServerSession.self) private var session
    @Environment(Navigator.self) private var navigator
    @Environment(SheetPresenter.self) private var sheets

    var body: some View {
        Button("Play") { session.player.play(songs) }
        Button("Play Next") { session.player.playNext(songs) }
        Button("Add to Queue") { session.player.addToQueue(songs) }
        if let song = songs.first, songs.count == 1 {
            Button("Instant Mix") { Task { await instantMix(song) } }
        }
        Divider()
        Button("Add to Playlist…") { sheets.present(.addToPlaylist(songs)) }
        if let song = songs.first, songs.count == 1 {
            Button(session.stars.isStarred(song) ? "Remove from Starred" : "Star") {
                Task { await session.stars.toggle(song) }
            }
        }
        downloadButton
        if let song = songs.first, songs.count == 1 {
            Divider()
            if let albumID = song.albumID {
                Button("Go to Album") { navigator.open(.album(id: albumID)) }
            }
            if let artistID = song.artistID {
                Button("Go to Artist") { navigator.open(.artist(id: artistID)) }
            }
            if session.features.hasShares {
                Button("Share…") { sheets.present(.share(ids: [song.id], name: song.title ?? "Track")) }
            }
            Button("Track Info") { sheets.present(.trackInfo(song)) }
        }
    }

    @ViewBuilder private var downloadButton: some View {
        let downloaded = songs.filter { session.downloads.isDownloaded($0.id) }
        if !downloaded.isEmpty, downloaded.count == songs.count {
            Button("Remove Download") { Task { await session.downloads.delete(downloaded.map(\.id)) } }
        } else {
            Button("Download") { session.downloads.download(songs, from: source) }
        }
    }

    private func instantMix(_ song: Song) async {
        do throws(SubsonicError) {
            let mix = try await session.sources.instantMix(for: song)
            session.player.playNext(mix)
        } catch {
            sheets.present(.message(title: "Instant Mix", text: error.userMessage))
        }
    }
}

struct AlbumMenu: View {
    let album: Album

    @Environment(ServerSession.self) private var session
    @Environment(SheetPresenter.self) private var sheets

    var body: some View {
        Button("Play") { withSongs { session.player.play($0) } }
        Button("Shuffle") { withSongs { session.player.playShuffled($0) } }
        Button("Play Next") { withSongs { session.player.playNext($0) } }
        Button("Add to Queue") { withSongs { session.player.addToQueue($0) } }
        Divider()
        Button("Add to Playlist…") { withSongs { sheets.present(.addToPlaylist($0)) } }
        Button(session.stars.isStarred(album) ? "Remove from Starred" : "Star") {
            Task { await session.stars.toggle(album) }
        }
        Button("Download") { withSongs { session.downloads.download($0) } }
        if session.features.hasShares {
            Button("Share…") { sheets.present(.share(ids: [album.id], name: album.name ?? "Album")) }
        }
    }

    private func withSongs(_ action: @escaping @MainActor ([Song]) -> Void) {
        Task {
            do throws(SubsonicError) {
                try await action(session.sources.songs(ofAlbum: album.id))
            } catch {
                sheets.present(.message(title: album.name ?? "Album", text: error.userMessage))
            }
        }
    }
}

struct ArtistMenu: View {
    let artist: Artist

    @Environment(ServerSession.self) private var session
    @Environment(SheetPresenter.self) private var sheets

    var body: some View {
        Button("Play") { withSongs({ () throws(SubsonicError) in
            try await session.sources.songs(ofArtist: artist.id) }) { session.player.play($0) } }
        Button("Shuffle") {
            withSongs({ () throws(SubsonicError) in
                try await session.sources.songs(ofArtist: artist.id) }) { session.player.playShuffled($0) }
        }
        Button("Artist Radio") { withSongs({ () throws(SubsonicError) in
            try await session.sources.artistMix(artist) }) { session.player.play($0) } }
        Divider()
        Button(session.stars.isStarred(artist) ? "Remove from Starred" : "Star") {
            Task { await session.stars.toggle(artist) }
        }
    }

    private func withSongs(
        _ fetch: @escaping @MainActor () async throws(SubsonicError) -> [Song],
        then action: @escaping @MainActor ([Song]) -> Void
    ) {
        Task {
            do throws(SubsonicError) {
                let songs = try await fetch()
                if songs.isEmpty {
                    sheets.present(.message(title: artist.name ?? "Artist", text: "The server found nothing to play."))
                } else {
                    action(songs)
                }
            } catch {
                sheets.present(.message(title: artist.name ?? "Artist", text: error.userMessage))
            }
        }
    }
}

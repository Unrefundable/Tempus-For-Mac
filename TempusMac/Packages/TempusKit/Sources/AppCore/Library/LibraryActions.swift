import Foundation
import Observation
import os
import Persistence
import SubsonicAPI

/// Why a playlist edit can't be saved, in upstream's words.
public enum PlaylistEditError: Error, Equatable, Sendable {
    /// A playlist has to keep at least one track; Delete removes it.
    case wouldBeEmpty
    case missingName
    case server(SubsonicError)

    public var message: String {
        switch self {
        case .wouldBeEmpty: "A playlist must keep at least one track. Use Delete to remove the playlist."
        case .missingName: "Enter a name for the playlist."
        case let .server(error): error.userMessage
        }
    }
}

/// Creating, editing, pinning and deleting playlists (Phase 7).
public struct PlaylistService: Sendable {
    let client: SubsonicClient
    let pins: PinnedPlaylistStore
    let serverID: String

    public func create(name: String, songs: [Song] = []) async throws(PlaylistEditError) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw .missingName }
        do throws(SubsonicError) {
            _ = try await client.send(.createPlaylist(name: name, songIDs: songs.map(\.id)))
        } catch {
            throw .server(error)
        }
    }

    public func add(_ songs: [Song], to playlist: Playlist) async throws(PlaylistEditError) {
        guard !songs.isEmpty else { return }
        do throws(SubsonicError) {
            _ = try await client.send(.updatePlaylist(id: playlist.id, songIDsToAdd: songs.map(\.id)))
        } catch {
            throw .server(error)
        }
    }

    /// Writes the list exactly as edited: every track the server had is removed and the edited
    /// list added in order, with the new name, in one request. `serverCount` must come from a
    /// fresh fetch, never the offline cache, or tracks added since would be lost.
    public func save(
        playlistID: String,
        name: String,
        serverCount: Int,
        songs: [Song]
    ) async throws(PlaylistEditError) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw .missingName }
        guard !songs.isEmpty else { throw .wouldBeEmpty }
        do throws(SubsonicError) {
            _ = try await client.send(.updatePlaylist(
                id: playlistID,
                name: name,
                songIDsToAdd: songs.map(\.id),
                songIndexesToRemove: Array(0 ..< serverCount)
            ))
        } catch {
            throw .server(error)
        }
    }

    public func delete(_ playlist: Playlist) async throws(PlaylistEditError) {
        do throws(SubsonicError) {
            _ = try await client.send(.deletePlaylist(id: playlist.id))
            try? await pins.unpin(playlist.id, server: serverID)
        } catch {
            throw .server(error)
        }
    }

    /// Upstream's faves are kept on the device, not the server.
    public func faves() async -> Set<String> {
        await (try? Set(pins.pinned(server: serverID))) ?? []
    }

    public func setFave(_ isFave: Bool, playlistID: String) async {
        if isFave {
            try? await pins.pin(playlistID, server: serverID)
        } else {
            try? await pins.unpin(playlistID, server: serverID)
        }
    }
}

/// What the server offers beyond browsing. Navidrome answers HTTP 501 for podcasts and shares, so
/// those screens hide.
@MainActor
@Observable
public final class ServerFeatures {
    public private(set) var hasPodcasts = true
    public private(set) var hasShares = true
    public private(set) var musicFolders: [MusicFolder] = []

    @ObservationIgnored private let client: SubsonicClient

    init(client: SubsonicClient) {
        self.client = client
    }

    func probe() async {
        async let podcasts = Self.isAvailable { [client] () throws(SubsonicError) in
            _ = try await client.send(.podcasts(includeEpisodes: false))
        }
        async let shares = Self.isAvailable { [client] () throws(SubsonicError) in
            _ = try await client.send(.shares)
        }
        async let folders = try? client.send(.musicFolders)
        hasPodcasts = await podcasts
        hasShares = await shares
        musicFolders = await folders ?? []
    }

    /// Only a definite "not implemented" hides a feature; offline, it stays.
    private static func isAvailable(_ call: () async throws(SubsonicError) -> Void) async -> Bool {
        do throws(SubsonicError) {
            try await call()
            return true
        } catch {
            return !error.isNotImplemented
        }
    }

    /// For tests and previews.
    func set(hasPodcasts: Bool, hasShares: Bool) {
        self.hasPodcasts = hasPodcasts
        self.hasShares = hasShares
    }
}

/// Fetches what a play button needs: albums, artists, folders, Instant Mix, podcast episodes.
public struct PlaybackSources: Sendable {
    /// Folder playback stops collecting here, so a click on the root can't fetch the whole library.
    public static let folderTrackLimit = 2000
    static let instantMixCount = 50

    let client: SubsonicClient

    public func songs(ofAlbum id: String) async throws(SubsonicError) -> [Song] {
        try await client.send(.album(id: id)).songs
    }

    /// Every album of the artist in order, as upstream's artist play and shuffle buttons.
    public func songs(ofArtist id: String) async throws(SubsonicError) -> [Song] {
        let artist = try await client.send(.artist(id: id))
        var songs: [Song] = []
        for album in artist.albums {
            try songs += await client.send(.album(id: album.id)).songs
        }
        return songs
    }

    /// Upstream's artist radio: similar songs to the artist, else its top songs.
    public func artistMix(_ artist: Artist) async throws(SubsonicError) -> [Song] {
        let similar = try await client.send(.similarSongs(artistID: artist.id, count: Self.instantMixCount))
        if !similar.isEmpty {
            return similar
        }
        guard let name = artist.name else { return [] }
        return try await client.send(.topSongs(artist: name, count: Self.instantMixCount))
    }

    /// Instant Mix: the song again, then songs similar to it (getSimilarSongs).
    public func instantMix(for song: Song) async throws(SubsonicError) -> [Song] {
        let similar = try await client.send(.similarSongs(id: song.id, count: Self.instantMixCount))
        return [song] + similar.filter { $0.id != song.id }
    }

    /// Every audio track in a folder and its subfolders, depth first, without videos.
    public func songs(inFolder id: String) async throws(SubsonicError) -> [Song] {
        var songs: [Song] = []
        var folders = [id]
        var visited: Set<String> = []
        while let folder = folders.popLast(), songs.count < Self.folderTrackLimit {
            guard visited.insert(folder).inserted else { continue }
            let directory = try await client.send(.musicDirectory(id: folder))
            songs += directory.children.filter { $0.isDir != true && $0.isVideo != true }
            folders += directory.children.filter { $0.isDir == true }.map(\.id).reversed()
        }
        return Array(songs.prefix(Self.folderTrackLimit))
    }

    /// The tracks of a folder-index artist entry (folder browsing).
    public func songs(inFolders ids: [String]) async throws(SubsonicError) -> [Song] {
        var songs: [Song] = []
        for id in ids where songs.count < Self.folderTrackLimit {
            try songs += await self.songs(inFolder: id)
        }
        return Array(songs.prefix(Self.folderTrackLimit))
    }

    /// Continue Listening: the track from its spot, then the rest of its album.
    public func resumeQueue(for bookmark: Bookmark) async -> (songs: [Song], index: Int) {
        let song = bookmark.entry
        guard song.type != "podcast", let albumID = song.albumID,
              let album = try? await client.send(.album(id: albumID)),
              let index = album.songs.firstIndex(where: { $0.id == song.id })
        else { return ([song], 0) }
        return (album.songs, index)
    }
}

public extension PodcastEpisode {
    /// The queue entry that plays it. Only episodes the server has downloaded have a stream.
    func song(channelTitle: String?) -> Song? {
        guard let streamID, status == nil || status == "completed" else { return nil }
        return Song(
            id: streamID,
            title: title,
            album: channelTitle ?? album,
            artist: artist ?? channelTitle,
            year: year,
            genre: genre,
            coverArtID: coverArtID,
            suffix: suffix,
            contentType: contentType,
            duration: duration,
            bitrate: bitrate,
            type: "podcast",
            size: size
        )
    }
}

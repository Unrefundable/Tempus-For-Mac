// swiftlint:disable no_print
// Diagnostic output for a person running these tests by hand; os.Logger would not reach the terminal.

import Foundation
@testable import SubsonicAPI
import Testing

/// Settings for the live tests, read from the environment that `scripts/live-test.sh` sets.
enum LiveServer {
    static var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }

    static var isConfigured: Bool {
        environment["TEMPUS_LIVE_SERVER"] != nil
    }

    static func auth() throws -> SubsonicAuth {
        let user = try #require(environment["TEMPUS_LIVE_USER"])
        let password = try #require(environment["TEMPUS_LIVE_PASSWORD"])
        let plaintext = environment["TEMPUS_LIVE_PLAINTEXT"] == "1"
        return SubsonicAuth(
            username: user,
            credential: plaintext ? .plaintext(password: password) : .tokenized(password: password)
        )
    }

    static func client(address: String? = nil) throws -> SubsonicClient {
        let text = try address ?? #require(environment["TEMPUS_LIVE_SERVER"])
        return try SubsonicClient(server: ServerAddress(text), auth: auth())
    }
}

/// Read-only checks against a real server: nothing is starred, scrobbled, created or deleted.
/// The point is to prove every model decodes real responses, so decoding errors always fail,
/// while "not supported" answers from the server are reported and skipped.
@Suite("Live server (read-only)", .enabled(if: LiveServer.isConfigured), .serialized)
struct LiveServerTests {
    let client: SubsonicClient

    init() throws {
        client = try LiveServer.client()
    }

    /// Runs `operation`; a `status: failed` answer or HTTP 501 means the server lacks the feature.
    private func optional<Value>(
        _ name: String,
        _ operation: () async throws(SubsonicError) -> Value
    ) async throws -> Value? {
        do {
            return try await operation()
        } catch let .server(code, message) {
            print("  - \(name): not available on this server (error \(code.rawValue): \(message ?? "no message"))")
            return nil
        } catch where error.isNotImplemented {
            print("  - \(name): not implemented by this server (HTTP 501)")
            return nil
        }
    }

    private func report(_ name: String, _ count: Int) {
        print("  ✓ \(name): \(count)")
    }

    @Test("Connects and identifies the server")
    func ping() async throws {
        let info = try await client.send(.ping)

        let type = info.type ?? "classic Subsonic"
        let version = info.serverVersion ?? "?"
        print("  ✓ server: \(type) \(version), API \(info.apiVersion), OpenSubsonic: \(info.isOpenSubsonic)")
        if info.isOpenSubsonic {
            let extensions = try await client.send(.openSubsonicExtensions)
            print("  ✓ extensions: \(extensions.map(\.name).sorted().joined(separator: ", "))")
        }
    }

    @Test("Browses artists, an artist, an album and a song")
    func browse() async throws {
        try await report("music folders", client.send(.musicFolders).count)
        try await report("genres", client.send(.genres).count)

        let indexes = try await client.send(.artists())
        let artists = indexes.indexes.flatMap(\.artists)
        report("artists", artists.count)

        let artistID = try #require(artists.first(where: { ($0.albumCount ?? 0) > 0 })?.id, "No artist with albums")
        let artist = try await client.send(.artist(id: artistID))
        report("albums of first artist", artist.albums.count)
        _ = try await optional("artist info") { () async throws(SubsonicError) in
            try await client.send(.artistInfo(id: artistID))
        }

        let albumID = try #require(artist.albums.first?.id)
        let album = try await client.send(.album(id: albumID))
        report("songs on first album", album.songs.count)
        _ = try await optional("album info") { () async throws(SubsonicError) in
            try await client.send(.albumInfo(id: albumID))
        }

        let songID = try #require(album.songs.first?.id)
        let song = try await client.send(.song(id: songID))
        #expect(song.id == songID)
    }

    @Test("Decodes every album list type")
    func albumLists() async throws {
        let types: [AlbumListType] = [
            .newest, .random, .recent, .frequent, .highest, .alphabeticalByName, .alphabeticalByArtist, .starred,
            .byYear(from: 1900, to: 2100),
        ]
        for type in types {
            try await report("album list \(type.name)", client.send(.albumList(type, size: 100)).count)
        }
        if let genre = try await client.send(.genres).first?.name {
            try await report("album list byGenre", client.send(.albumList(.byGenre(genre), size: 100)).count)
        }
    }

    @Test("Decodes song lists, search and starred items")
    func songsAndSearch() async throws {
        let random = try await client.send(.randomSongs(size: 100))
        report("random songs", random.count)

        if let genre = try await client.send(.genres).first?.name {
            try await report("songs by genre", client.send(.songsByGenre(genre, count: 100)).count)
        }
        if let song = random.first {
            let similar = try await optional("similar songs") { () async throws(SubsonicError) in
                try await client.send(.similarSongs(id: song.id, count: 20))
            }
            report("similar songs", similar?.count ?? 0)
            if let artistID = song.artistID {
                let mix = try await optional("similar songs by artist") { () async throws(SubsonicError) in
                    try await client.send(.similarSongs(artistID: artistID, count: 20))
                }
                report("similar songs by artist", mix?.count ?? 0)
            }
            if let artist = song.artist {
                let top = try await optional("top songs") { () async throws(SubsonicError) in
                    try await client.send(.topSongs(artist: artist, count: 20))
                }
                report("top songs", top?.count ?? 0)
                let found = try await client.send(.search(String(artist.prefix(4))))
                report("search results", found.artists.count + found.albums.count + found.songs.count)
            }
        }

        let starred = try await client.send(.starred())
        report("starred items", starred.artists.count + starred.albums.count + starred.songs.count)
    }

    @Test("Decodes playlists and folder browsing")
    func playlistsAndFolders() async throws {
        let playlists = try await client.send(.playlists)
        report("playlists", playlists.count)
        if let first = playlists.first {
            try await report("entries in first playlist", client.send(.playlist(id: first.id)).entries.count)
        }

        let folders = try await optional("folder indexes") { () async throws(SubsonicError) in
            try await client.send(.indexes())
        }
        if let entry = folders?.indexes.first?.artists.first {
            try await report("items in first folder", client.send(.musicDirectory(id: entry.id)).children.count)
        }
    }

    @Test("Decodes podcasts, radio, shares, bookmarks, play queue, lyrics and scan status")
    func everythingElse() async throws {
        let channels = try await optional("podcasts") { () async throws(SubsonicError) in
            try await client.send(.podcasts(includeEpisodes: true))
        }
        report("podcast channels", channels?.count ?? 0)
        let newest = try await optional("newest podcasts") { () async throws(SubsonicError) in
            try await client.send(.newestPodcasts(count: 20))
        }
        report("newest episodes", newest?.count ?? 0)
        let stations = try await optional("radio") { () async throws(SubsonicError) in
            try await client.send(.internetRadioStations)
        }
        report("radio stations", stations?.count ?? 0)
        let shares = try await optional("shares") { () async throws(SubsonicError) in
            try await client.send(.shares)
        }
        report("shares", shares?.count ?? 0)
        let bookmarks = try await optional("bookmarks") { () async throws(SubsonicError) in
            try await client.send(.bookmarks)
        }
        report("bookmarks", bookmarks?.count ?? 0)
        let queue = try await optional("play queue") { () async throws(SubsonicError) in
            try await client.send(.playQueue)
        }
        report("saved play queue entries", queue??.entries.count ?? 0)
        let scan = try await optional("scan status") { () async throws(SubsonicError) in
            try await client.send(.scanStatus)
        }
        print("  ✓ scan status: scanning \(scan?.isScanning ?? false), items \(scan?.count ?? 0)")

        if let song = try await client.send(.randomSongs(size: 1)).first {
            let lyrics = try await optional("lyrics by song id") { () async throws(SubsonicError) in
                try await client.send(.lyrics(songID: song.id))
            }
            report("lyrics sets for a random song", lyrics?.count ?? 0)
        }
    }

    @Test("Stream and cover-art URLs return audio and an image")
    func media() async throws {
        let session = URLSession(configuration: .ephemeral)
        let song = try #require(try await client.send(.randomSongs(size: 1)).first)

        var stream = try URLRequest(url: client.streamURL(id: song.id))
        stream.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        let (_, streamResponse) = try await session.data(for: stream)
        let streamHTTP = try #require(streamResponse as? HTTPURLResponse)
        #expect([200, 206].contains(streamHTTP.statusCode))
        print("  ✓ stream: HTTP \(streamHTTP.statusCode), \(streamHTTP.mimeType ?? "?")")

        if let cover = song.coverArtID {
            let (data, coverResponse) = try await session.data(from: client.coverArtURL(id: cover, size: 300))
            let coverHTTP = try #require(coverResponse as? HTTPURLResponse)
            #expect(coverHTTP.statusCode == 200)
            print("  ✓ cover art: HTTP \(coverHTTP.statusCode), \(coverHTTP.mimeType ?? "?"), \(data.count) bytes")
        }
    }

    @Test("Home and away switching with the real addresses")
    func addressSwitching() async throws {
        guard let local = LiveServer.environment["TEMPUS_LIVE_LOCAL"], !local.isEmpty else {
            print("  - address switching: no local URL given, skipped")
            return
        }
        let auth = try LiveServer.auth()
        let switcher = try AddressSwitcher(
            publicAddress: client.server,
            localAddress: ServerAddress(local),
            isReachable: { address in
                // The server answering at all, even with an auth error, proves the address works.
                do {
                    _ = try await SubsonicClient(server: address, auth: auth, timeout: 5).send(.ping)
                    return true
                } catch let error as SubsonicError {
                    guard case .server = error else { return false }
                    return true
                } catch {
                    return false
                }
            }
        )

        let chosen = await switcher.refresh()
        let label = chosen.map { $0 == client.server ? "public" : "local" } ?? "unreachable"
        print("  ✓ address switching chose: \(label)")
        #expect(chosen != nil)
    }
}

// swiftlint:enable no_print

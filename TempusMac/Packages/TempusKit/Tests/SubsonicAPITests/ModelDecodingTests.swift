import Foundation
@testable import SubsonicAPI
import Testing

private func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

private func decode<Response>(_ request: SubsonicRequest<Response>, body: String) async throws -> Response {
    let client = try SubsonicClient(
        server: ServerAddress("https://music.example.com"),
        auth: SubsonicAuth(username: "alice", credential: .token(token: "t", salt: "s")),
        transport: StubTransport(body: body)
    )
    return try await client.send(request)
}

private func decode<Response>(_ request: SubsonicRequest<Response>, fixture name: String) async throws -> Response {
    try await decode(request, body: fixture(name))
}

/// Wraps an element in a minimal classic `ok` response.
private func ok(_ element: String) -> String {
    #"{"subsonic-response":{"status":"ok","version":"1.15.0",\#(element)}}"#
}

@Suite("Model decoding from recorded-style fixtures")
struct ModelDecodingTests {
    @Test("OpenSubsonic album with songs, ReplayGain and extended fields")
    func openSubsonicAlbum() async throws {
        let album = try await decode(.album(id: "al-blue-train"), fixture: "getAlbum")

        #expect(album.id == "al-blue-train")
        #expect(album.name == "Blue Train")
        #expect(album.artistID == "ar-coltrane")
        #expect(album.coverArtID == "al-blue-train_0")
        #expect(album.year == 1957)
        #expect(album.genres.map(\.name) == ["Jazz", "Hard Bop"])
        #expect(album.originalReleaseDate == ReleaseDate(year: 1957, month: 9, day: 15))
        #expect(album.starred != nil)
        #expect(album.songs.count == 2)

        let first = try #require(album.songs.first)
        #expect(first.bitrate == 1015)
        #expect(first.samplingRate == 44100)
        #expect(first.coverArtID == "mf-s-blue-train_0")
        #expect(first.parentID == "al-blue-train")
        #expect(first.albumArtist == "John Coltrane")
        #expect(first.replayGain?.trackGain == -7.12)
        #expect(first.replayGain?.albumPeak == 0.991)
        #expect(first.created != nil)

        let second = album.songs[1]
        #expect(second.created == nil)
        #expect(second.starred == nil)
        #expect(second.replayGain?.trackGain == nil)
    }

    @Test("Classic album with numeric ids, one song as an object and legacy albumArtist")
    func classicAlbum() async throws {
        let album = try await decode(.album(id: "1042"), fixture: "getAlbum-classic")

        #expect(album.id == "1042")
        #expect(album.artistID == "77")
        #expect(album.created != nil)
        let song = try #require(album.songs.first)
        #expect(album.songs.count == 1)
        #expect(song.id == "99001")
        #expect(song.parentID == "1042")
        #expect(song.albumArtist == "Miles Davis")
        #expect(song.transcodedSuffix == "opus")
    }

    @Test("Artist index with an index holding a single artist object")
    func artistIndexes() async throws {
        let indexes = try await decode(.artists(), fixture: "getArtists")

        #expect(indexes.ignoredArticles == "The El La Los Las Le Les")
        #expect(indexes.indexes.map(\.name) == ["C", "M"])
        #expect(indexes.indexes[0].artists.count == 2)
        #expect(indexes.indexes[1].artists.map(\.name) == ["Miles Davis"])
        #expect(indexes.indexes[0].artists[0].imageURL?
            .absoluteString == "https://music.example.com/share/img/ar-coltrane")
    }

    @Test("Artist with albums")
    func artist() async throws {
        let artist = try await decode(.artist(id: "ar-coltrane"), fixture: "getArtist")

        #expect(artist.name == "John Coltrane")
        #expect(artist.userRating == 4)
        #expect(artist.albums.map(\.id) == ["al-blue-train", "al-giant-steps"])
    }

    @Test("Artist info with similar artists")
    func artistInfo() async throws {
        let info = try await decode(.artistInfo(id: "ar-coltrane"), fixture: "getArtistInfo2")

        #expect(info.biography?.hasPrefix("John William Coltrane") == true)
        #expect(info.largeImageURL?.absoluteString == "https://images.example.com/large.jpg")
        #expect(info.similarArtists.map(\.id) == ["ar-davis", "ar-rollins"])
    }

    @Test("Playlists list where the server sent a single playlist object")
    func playlists() async throws {
        let playlists = try await decode(.playlists, fixture: "getPlaylists")

        let playlist = try #require(playlists.first)
        #expect(playlists.count == 1)
        #expect(playlist.id == "15")
        #expect(playlist.isPublic == true)
        #expect(playlist.allowedUsers == ["bob"])
        #expect(playlist.entries.isEmpty)
    }

    @Test("Playlist entries keep duplicates")
    func playlist() async throws {
        let playlist = try await decode(.playlist(id: "pl-late-night"), fixture: "getPlaylist")

        #expect(playlist.entries.map(\.id) == ["s-blue-train", "s-blue-train"])
        #expect(playlist.isPublic == false)
    }

    @Test("search3 results")
    func search() async throws {
        let result = try await decode(.search("blue"), fixture: "search3")

        #expect(result.artists.count == 1)
        #expect(result.albums.count == 1)
        #expect(result.songs.map(\.title) == ["Blue Train", "Moment's Notice"])
    }

    @Test("An empty starred2 element decodes to empty lists")
    func emptyStarred() async throws {
        let starred = try await decode(.starred(), body: ok(#""starred2":{}"#))

        #expect(starred.artists.isEmpty && starred.albums.isEmpty && starred.songs.isEmpty)
    }

    @Test("Podcast channels, episodes and channel errors")
    func podcasts() async throws {
        let channels = try await decode(.podcasts(includeEpisodes: true), fixture: "getPodcasts")

        #expect(channels.count == 2)
        let episodes = channels[0].episodes
        #expect(episodes.map(\.id) == ["pe-1", "pe-2"])
        #expect(episodes[0].streamID == "pe-1-stream")
        #expect(episodes[0].publishDate != nil)
        #expect(episodes[0].duration == 2700)
        #expect(episodes[1].status == "skipped")
        #expect(channels[1].errorMessage == "Feed not found")
        #expect(channels[1].episodes.isEmpty)
    }

    @Test("Newest podcast episodes")
    func newestPodcasts() async throws {
        let episodes = try await decode(
            .newestPodcasts(count: 5),
            body: ok(#""newestPodcasts":{"episode":{"id":"pe-9","title":"Latest","channelId":"pc-1"}}"#)
        )

        #expect(episodes.map(\.id) == ["pe-9"])
    }

    @Test("A single bookmark object is read as a list of one")
    func singleBookmark() async throws {
        let bookmarks = try await decode(.bookmarks, fixture: "getBookmarks-single")

        let bookmark = try #require(bookmarks.first)
        #expect(bookmarks.count == 1)
        #expect(bookmark.position == 5000)
        #expect(bookmark.entry.id == "9")
    }

    @Test("Saved play queue")
    func playQueue() async throws {
        let queue = try #require(try await decode(.playQueue, fixture: "getPlayQueue"))

        #expect(queue.current == "s-moments-notice")
        #expect(queue.position == 120_500)
        #expect(queue.entries.count == 2)
        #expect(queue.changedBy == "Tempus")
    }

    @Test("No saved play queue is nil, not an error")
    func missingPlayQueue() async throws {
        let queue = try await decode(.playQueue, body: ok(#""ignored":true"#))

        #expect(queue == nil)
    }

    @Test("Structured lyrics, synced and unsynced")
    func structuredLyrics() async throws {
        let lyrics = try await decode(.lyrics(songID: "s1"), fixture: "getLyricsBySongId")

        #expect(lyrics.count == 2)
        #expect(lyrics[0].isSynced)
        #expect(lyrics[0].offset == -100)
        #expect(lyrics[0].lines.map(\.start) == [0, 2500])
        #expect(lyrics[1].isSynced == false)
        #expect(lyrics[1].lines.first?.start == nil)
        #expect(lyrics[1].lines.first?.value == "Unsynced text")
    }

    @Test("Classic lyrics, present or empty")
    func classicLyrics() async throws {
        let found = try await decode(
            .lyrics(artist: "A", title: "T"),
            body: ok(#""lyrics":{"artist":"A","title":"T","value":"La la la"}"#)
        )
        let empty = try await decode(.lyrics(artist: "A", title: "T"), body: ok(#""lyrics":{}"#))

        #expect(found?.text == "La la la")
        #expect(empty?.text == nil)
    }

    @Test("Folder indexes with shortcut, single-artist index and loose child")
    func indexes() async throws {
        let indexes = try await decode(.indexes(), fixture: "getIndexes")

        #expect(indexes.shortcuts.map(\.name) == ["Podcasts"])
        #expect(indexes.indexes.map(\.name) == ["C", "M"])
        #expect(indexes.indexes[1].artists.first?.starred != nil)
        #expect(indexes.children.map(\.id) == ["s-loose"])
    }

    @Test("Music directory with sub-folders and files")
    func musicDirectory() async throws {
        let directory = try await decode(.musicDirectory(id: "dir-coltrane"), fixture: "getMusicDirectory")

        #expect(directory.name == "John Coltrane")
        #expect(directory.parentID == "root")
        #expect(directory.children.map(\.isDir) == [true, false])
    }

    @Test("Shares")
    func shares() async throws {
        let shares = try await decode(.shares, fixture: "getShares")

        let share = try #require(shares.first)
        #expect(share.url?.absoluteString == "https://music.example.com/share/sh-1")
        #expect(share.expires != nil)
        #expect(share.visitCount == 3)
        #expect(share.entries.map(\.id) == ["s-blue-train"])
    }

    @Test("Internet radio stations with numeric ids and missing homepages")
    func radioStations() async throws {
        let stations = try await decode(.internetRadioStations, fixture: "getInternetRadioStations")

        #expect(stations.map(\.id) == ["1", "2"])
        #expect(stations[0].streamURL?.absoluteString == "https://stream.example.com/jazz.mp3")
        #expect(stations[1].homePageURL == nil)
    }

    @Test("OpenSubsonic extensions")
    func extensions() async throws {
        let extensions = try await decode(.openSubsonicExtensions, fixture: "getOpenSubsonicExtensions")

        #expect(extensions.map(\.name) == ["transcodeOffset", "formPost", "songLyrics"])
        #expect(extensions[0].versions == [1])
    }

    @Test("Song lists from every list endpoint", arguments: [
        ("randomSongs", SubsonicRequest<[Song]>.randomSongs(size: 2)),
        ("songsByGenre", .songsByGenre("Jazz")),
        ("similarSongs", .similarSongs(id: "s1")),
        ("similarSongs2", .similarSongs(artistID: "ar1")),
        ("topSongs", .topSongs(artist: "John Coltrane")),
    ])
    func songLists(element: String, request: SubsonicRequest<[Song]>) async throws {
        let songs = try await decode(request, body: ok(#""\#(element)":{"song":[{"id":"a"},{"id":"b"}]}"#))
        let empty = try await decode(request, body: ok(#""\#(element)":{}"#))

        #expect(songs.map(\.id) == ["a", "b"])
        #expect(empty.isEmpty)
    }

    @Test("Album list, genres, music folders, album info, single song and scan status")
    func smallElements() async throws {
        let albums = try await decode(.albumList(.newest), body: ok(#""albumList2":{"album":[{"id":"a"}]}"#))
        let genres = try await decode(
            .genres,
            body: ok(#""genres":{"genre":[{"value":"Jazz","songCount":10,"albumCount":2}]}"#)
        )
        let folders = try await decode(
            .musicFolders,
            body: ok(#""musicFolders":{"musicFolder":[{"id":1,"name":"Music"}]}"#)
        )
        let info = try await decode(.albumInfo(id: "a"), body: ok(#""albumInfo":{"notes":"Liner notes"}"#))
        let song = try await decode(.song(id: "s"), body: ok(#""song":{"id":"s","title":"T"}"#))
        let scan = try await decode(.scanStatus, body: ok(#""scanStatus":{"scanning":true,"count":1234}"#))

        #expect(albums.map(\.id) == ["a"])
        #expect(genres == [Genre(name: "Jazz", songCount: 10, albumCount: 2)])
        #expect(folders.map(\.id) == ["1"])
        #expect(info.notes == "Liner notes")
        #expect(song.title == "T")
        #expect(scan == ScanStatus(isScanning: true, count: 1234))
    }

    @Test("Scan status carries the server's last scan time when it sends one")
    func scanStatusLastScan() async throws {
        let scan = try await decode(
            .scanStatus,
            body: ok(#""scanStatus":{"scanning":false,"count":5360,"lastScan":"2026-11-07T17:10:04.123Z"}"#)
        )

        #expect(scan == ScanStatus(isScanning: false, count: 5360, lastScan: "2026-11-07T17:10:04.123Z"))
    }

    @Test("A null container is treated like a missing one")
    func nullContainer() async throws {
        let albums = try await decode(.albumList(.newest), body: ok(#""albumList2":null"#))
        let queue = try await decode(.playQueue, body: ok(#""playQueue":null"#))

        #expect(albums.isEmpty)
        #expect(queue == nil)
    }

    @Test("A bad element inside a list reports that element's error")
    func listElementErrorIsKept() async throws {
        let error = await #expect(throws: SubsonicError.self) {
            try await decode(.albumList(.newest), body: ok(#""albumList2":{"album":[{"id":"a"},{"name":"no id"}]}"#))
        }

        guard case let .decoding(description) = error else { Issue.record("Expected .decoding"); return }
        #expect(description.contains("id"))
        #expect(!description.contains("Expected to decode Dictionary"))
    }

    @Test("Write endpoints accept an empty ok response")
    func emptyResponses() async throws {
        let response = try await decode(.star(songIDs: ["1"]), body: ok(#""ignored":true"#))

        #expect(response == EmptyResponse())
    }
}

@Suite("Starred decoding")
struct StarredDecodingTests {
    @Test("Starred songs decode for Favorites")
    func starredSongs() async throws {
        let starred = try await decode(.starred(musicFolderID: "1"), body: ok(#"""
        "starred2":{"song":[
            {"id":"s1","title":"Blue Train","artist":"John Coltrane","starred":"2024-05-01T10:00:00Z"},
            {"id":"s2","title":"Naima","starred":"2024-05-02T10:00:00Z"}
        ]}
        """#))

        #expect(starred.songs.map(\.id) == ["s1", "s2"])
        #expect(starred.songs.allSatisfy { $0.starred != nil })
        #expect(starred.albums.isEmpty && starred.artists.isEmpty)
    }
}

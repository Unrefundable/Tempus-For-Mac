import Foundation
@testable import SubsonicAPI
import Testing

private func pairs(_ request: SubsonicRequest<some Any>) -> [String] {
    request.parameters.map { "\($0.name)=\($0.value ?? "")" }
}

@Suite("Endpoint methods and parameters match upstream Tempus")
struct EndpointRequestTests {
    @Test("Browsing")
    func browsing() {
        #expect(SubsonicRequest.musicFolders.method == "getMusicFolders")
        #expect(SubsonicRequest.genres.method == "getGenres")
        #expect(pairs(.artists()) == [])
        #expect(pairs(.artists(musicFolderID: "3")) == ["musicFolderId=3"])
        #expect(SubsonicRequest.artists().method == "getArtists")
        #expect(pairs(.indexes(musicFolderID: "3")) == ["musicFolderId=3"])
        #expect(SubsonicRequest.musicDirectory(id: "d").method == "getMusicDirectory")
        #expect(pairs(.artist(id: "ar")) == ["id=ar"])
        #expect(pairs(.album(id: "al")) == ["id=al"])
        #expect(SubsonicRequest.song(id: "s").method == "getSong")
        #expect(SubsonicRequest.artistInfo(id: "ar").method == "getArtistInfo2")
        #expect(SubsonicRequest.albumInfo(id: "al").method == "getAlbumInfo2")
    }

    @Test("Album lists")
    func albumLists() {
        let newest = SubsonicRequest.albumList(.newest, size: 20, offset: 40)
        #expect(newest.method == "getAlbumList2")
        #expect(pairs(newest) == ["type=newest", "size=20", "offset=40"])
        #expect(pairs(.albumList(.byYear(from: 1950, to: 1960), size: 10))
            == ["type=byYear", "fromYear=1950", "toYear=1960", "size=10", "offset=0"])
        #expect(pairs(.albumList(.byGenre("Jazz"), musicFolderID: "2"))
            == ["type=byGenre", "genre=Jazz", "size=10", "offset=0", "musicFolderId=2"])
        #expect(pairs(.albumList(.alphabeticalByArtist)).first == "type=alphabeticalByArtist")
    }

    @Test("Song lists")
    func songLists() {
        #expect(SubsonicRequest.randomSongs(size: 50).method == "getRandomSongs")
        #expect(pairs(.randomSongs(size: 50, fromYear: 1990, toYear: 1999, genre: "Rock"))
            == ["size=50", "fromYear=1990", "toYear=1999", "genre=Rock"])
        #expect(pairs(.songsByGenre("Jazz", count: 20, offset: 40)) == ["genre=Jazz", "count=20", "offset=40"])
        #expect(SubsonicRequest.similarSongs(id: "s", count: 50).method == "getSimilarSongs")
        #expect(pairs(.similarSongs(id: "s", count: 50)) == ["id=s", "count=50"])
        #expect(SubsonicRequest.similarSongs(artistID: "ar").method == "getSimilarSongs2")
        #expect(pairs(.topSongs(artist: "John Coltrane", count: 10)) == ["artist=John Coltrane", "count=10"])
        #expect(SubsonicRequest.starred().method == "getStarred2")
    }

    @Test("Search")
    func search() {
        let request = SubsonicRequest.search("blue", artistCount: 5, albumCount: 10, songCount: 20, songOffset: 20)

        #expect(request.method == "search3")
        #expect(pairs(request) == [
            "query=blue", "artistCount=5", "artistOffset=0", "albumCount=10", "albumOffset=0",
            "songCount=20", "songOffset=20",
        ])
    }

    @Test("Playlists")
    func playlists() {
        #expect(SubsonicRequest.playlists.method == "getPlaylists")
        #expect(pairs(.playlist(id: "p")) == ["id=p"])
        #expect(pairs(.createPlaylist(name: "Mix", songIDs: ["1", "2"])) == ["name=Mix", "songId=1", "songId=2"])
        #expect(pairs(.updatePlaylist(id: "p", isPublic: true, songIDsToAdd: ["3"], songIndexesToRemove: [0, 4]))
            == ["playlistId=p", "public=true", "songIdToAdd=3", "songIndexToRemove=0", "songIndexToRemove=4"])
        #expect(pairs(.updatePlaylist(id: "p", name: "New name")) == ["playlistId=p", "name=New name"])
        #expect(pairs(.deletePlaylist(id: "p")) == ["id=p"])
    }

    @Test("Annotation")
    func annotation() {
        #expect(pairs(.star(songIDs: ["1", "2"], albumIDs: ["a"])) == ["id=1", "id=2", "albumId=a"])
        #expect(SubsonicRequest.unstar(artistIDs: ["ar"]).method == "unstar")
        #expect(pairs(.unstar(artistIDs: ["ar"])) == ["artistId=ar"])
        #expect(pairs(.setRating(id: "1", rating: 4)) == ["id=1", "rating=4"])
        #expect(pairs(.scrobble(id: "1", time: Date(timeIntervalSince1970: 1_700_000_000), submission: true))
            == ["id=1", "time=1700000000000", "submission=true"])
        #expect(pairs(.scrobble(id: "1", submission: false)) == ["id=1", "submission=false"])
    }

    @Test("Ratings are clamped to 0...5", arguments: [(-3, "0"), (0, "0"), (5, "5"), (9, "5")])
    func ratingClamped(rating: Int, expected: String) {
        #expect(pairs(.setRating(id: "1", rating: rating)).last == "rating=\(expected)")
    }

    @Test("Bookmarks and play queue")
    func bookmarks() {
        #expect(SubsonicRequest.bookmarks.method == "getBookmarks")
        #expect(pairs(.createBookmark(id: "1", position: 5000)) == ["id=1", "position=5000"])
        #expect(pairs(.deleteBookmark(id: "1")) == ["id=1"])
        #expect(SubsonicRequest.playQueue.method == "getPlayQueue")
        #expect(pairs(.savePlayQueue(songIDs: ["1", "2"], current: "2", position: 1500))
            == ["id=1", "id=2", "current=2", "position=1500"])
    }

    @Test("Podcasts")
    func podcasts() throws {
        #expect(pairs(.podcasts(includeEpisodes: false)) == ["includeEpisodes=false"])
        #expect(pairs(.podcasts(includeEpisodes: true, id: "pc")) == ["includeEpisodes=true", "id=pc"])
        #expect(pairs(.newestPodcasts(count: 5)) == ["count=5"])
        #expect(SubsonicRequest.refreshPodcasts.method == "refreshPodcasts")
        let feed = try #require(URL(string: "https://podcasts.example.com/feed.xml"))
        #expect(pairs(.createPodcastChannel(url: feed)) == ["url=https://podcasts.example.com/feed.xml"])
        #expect(SubsonicRequest.deletePodcastChannel(id: "pc").method == "deletePodcastChannel")
        #expect(SubsonicRequest.deletePodcastEpisode(id: "pe").method == "deletePodcastEpisode")
        #expect(SubsonicRequest.downloadPodcastEpisode(id: "pe").method == "downloadPodcastEpisode")
    }

    @Test("Internet radio")
    func radio() throws {
        let stream = try #require(URL(string: "https://stream.example.com/jazz.mp3"))
        let home = try #require(URL(string: "https://jazz.example.com"))
        #expect(SubsonicRequest.internetRadioStations.method == "getInternetRadioStations")
        #expect(pairs(.createInternetRadioStation(streamURL: stream, name: "Jazz", homePageURL: home))
            == ["streamUrl=https://stream.example.com/jazz.mp3", "name=Jazz", "homepageUrl=https://jazz.example.com"])
        #expect(pairs(.updateInternetRadioStation(id: "1", streamURL: stream, name: "Jazz"))
            == ["id=1", "streamUrl=https://stream.example.com/jazz.mp3", "name=Jazz"])
        #expect(pairs(.deleteInternetRadioStation(id: "1")) == ["id=1"])
    }

    @Test("Sharing")
    func sharing() {
        let expires = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(SubsonicRequest.shares.method == "getShares")
        #expect(pairs(.createShare(ids: ["1", "2"], description: "For Bob", expires: expires))
            == ["id=1", "id=2", "description=For Bob", "expires=1800000000000"])
        #expect(pairs(.updateShare(id: "sh", description: "New")) == ["id=sh", "description=New"])
        #expect(pairs(.deleteShare(id: "sh")) == ["id=sh"])
    }

    @Test("Lyrics and system")
    func lyricsAndSystem() {
        #expect(SubsonicRequest.lyrics(artist: "A", title: "T").method == "getLyrics")
        #expect(pairs(.lyrics(artist: "A", title: "T")) == ["artist=A", "title=T"])
        #expect(SubsonicRequest.lyrics(songID: "s").method == "getLyricsBySongId")
        #expect(pairs(.lyrics(songID: "s")) == ["id=s"])
        #expect(SubsonicRequest.openSubsonicExtensions.method == "getOpenSubsonicExtensions")
        #expect(SubsonicRequest.scanStatus.method == "getScanStatus")
        #expect(SubsonicRequest.startScan.method == "startScan")
    }
}

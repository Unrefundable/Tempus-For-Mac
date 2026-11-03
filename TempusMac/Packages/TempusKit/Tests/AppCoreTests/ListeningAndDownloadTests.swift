@testable import AppCore
import Foundation
import Persistence
import Playback
import SubsonicAPI
import Testing

@MainActor
struct ListeningSyncTests {
    let transport = RecordingTransport()
    let settings: AppSettings
    let player: PlayerController
    let sync: ListeningSync

    init() throws {
        settings = try AppSettings(defaults: #require(UserDefaults(suiteName: "ListeningSyncTests-\(UUID())")))
        let defaults = try #require(UserDefaults(suiteName: "ListeningSyncPlayer-\(UUID())"))
        player = try PlayerController(
            engine: FakeEngine(),
            source: SubsonicStreamSource(client: transport.client()),
            queueSaver: nil,
            serverID: "s1",
            settingsStore: PlaybackSettingsStore(defaults: defaults)
        )
        sync = try ListeningSync(player: player, client: transport.client(), settings: settings, now: { Date() })
    }

    static let episode = Song(id: "p1", title: "Episode", duration: 600, type: "podcast")
    static let next = Song(id: "p2", title: "Next", duration: 600, type: "podcast")

    @Test
    func `pausing a podcast saves its spot as a bookmark`() async {
        player.play([Self.episode])
        sync.playerChanged()
        player.seek(to: 120)
        player.pause()
        sync.playerChanged()
        await sync.settled()
        #expect(transport.query("createBookmark").first { $0.name == "position" }?.value == "120000")
    }

    @Test
    func `moving on keeps the old track's spot, or drops it when it played through`() async {
        player.play([Self.episode, Self.next, Self.episode])
        sync.playerChanged()
        player.seek(to: 100)
        sync.tick()
        player.next()
        sync.playerChanged()
        await sync.settled()
        #expect(transport.query("createBookmark").first { $0.name == "id" }?.value == "p1")

        player.seek(to: 595)
        sync.tick()
        player.next()
        sync.playerChanged()
        await sync.settled()
        #expect(transport.query("deleteBookmark").first { $0.name == "id" }?.value == "p2")
    }

    @Test
    func `stopping keeps the spot it stopped at`() async {
        player.play([Self.episode])
        sync.playerChanged()
        player.seek(to: 90)
        sync.tick()
        player.stop()
        sync.playerChanged()
        await sync.settled()
        #expect(transport.query("createBookmark").first { $0.name == "position" }?.value == "90000")
    }

    @Test
    func `a tick that sees the track change first still keeps the old track's spot`() async {
        player.play([Self.episode, Self.next])
        sync.playerChanged()
        player.seek(to: 100)
        sync.tick()
        player.next()
        sync.tick()
        await sync.settled()
        #expect(transport.query("createBookmark").first { $0.name == "id" }?.value == "p1")
        #expect(transport.query("createBookmark").first { $0.name == "position" }?.value == "100000")
    }

    @Test
    func `short music never gets a bookmark`() async {
        player.play([TestData.song("m1")])
        sync.playerChanged()
        player.seek(to: 50)
        player.pause()
        sync.playerChanged()
        await sync.settled()
        #expect(!transport.methods().contains("createBookmark"))
    }

    @Test
    func `the play queue is saved on pause only while syncing is on`() async {
        player.play([TestData.song("a"), TestData.song("b")])
        sync.playerChanged()
        player.pause()
        sync.playerChanged()
        await sync.settled()
        #expect(!transport.methods().contains("savePlayQueue"))

        settings.syncsPlayQueue = true
        player.resume()
        sync.playerChanged()
        player.pause()
        sync.playerChanged()
        await sync.settled()
        #expect(transport.query("savePlayQueue").filter { $0.name == "id" }.map(\.value) == ["a", "b"])
        #expect(transport.query("savePlayQueue").first { $0.name == "current" }?.value == "a")
    }

    @Test
    func `load queue restores the server's queue at its spot`() async throws {
        transport.set("getPlayQueue", RecordingTransport.ok(#"""
        "playQueue":{"current":"b","position":42000,"entry":[{"id":"a"},{"id":"b"}]}
        """#))
        try await sync.loadServerQueue()
        #expect(player.queue.current?.song.id == "b")
        #expect(player.position == 42)
    }
}

@MainActor
struct ScrobblerTests {
    @Test
    func `plays are recorded in history and scrobbled while scrobbling is on`() async throws {
        let database = try AppDatabase.inMemory()
        try await TestData.saveServer(in: database, id: "s1")
        let transport = RecordingTransport()
        let settings = try AppSettings(defaults: #require(UserDefaults(suiteName: "Scrobbler-\(UUID())")))
        let history = HistoryStore(database: database)
        let scrobbler = try Scrobbler(client: transport.client(), history: history, serverID: "s1", settings: settings)

        await scrobbler.handle(.nowPlaying(TestData.song("1")))
        await scrobbler.handle(.played(TestData.song("1"), at: Date(timeIntervalSince1970: 1000)))
        #expect(transport.methods() == ["scrobble", "scrobble"])
        #expect(transport.query("scrobble").first { $0.name == "submission" }?.value == "true")

        settings.scrobbles = false
        await scrobbler.handle(.played(TestData.song("2"), at: Date(timeIntervalSince1970: 2000)))
        #expect(transport.requests.count == 2)
        #expect(try await history.recentlyPlayed(server: "s1", limit: 5).map(\.id) == ["2", "1"])
    }
}

struct RadioTests {
    @Test
    func `the station form needs a name and a web stream address`() throws {
        var form = RadioStationForm()
        #expect(form.validated() == .failure(.missingName))
        form.name = "Jazz"
        form.streamAddress = "ftp://example.com/stream"
        #expect(form.validated() == .failure(.invalidStream))
        form.streamAddress = " https://radio.example.com/jazz "
        form.homePageAddress = "nonsense"
        #expect(form.validated() == .failure(.invalidHomePage))
        form.homePageAddress = ""
        #expect(try form.validated().get().streamURL.absoluteString == "https://radio.example.com/jazz")
    }

    @Test
    func `a station plays from its own address without the server's headers`() throws {
        let station = try RadioStation(
            id: "7", name: "Jazz", streamURL: #require(URL(string: "https://radio.example.com/jazz")),
            homePageURL: nil, coverArtURL: nil, origin: .local
        )
        let song = station.song
        #expect(song.type == RadioStation.songType)
        let source = try SessionStreamSource(
            remote: SubsonicStreamSource(client: RecordingTransport().client()), downloads: DownloadIndex()
        )
        let item = try source.streamItem(for: QueueItem(song: song), quality: .serverDefault)
        #expect(item.url == station.streamURL)
        #expect(item.headers.isEmpty)
    }

    @Test
    func `radio-browser results are parsed, keeping only playable ones`() async throws {
        struct Directory: HTTPTransport {
            func data(for request: URLRequest) async throws -> (Data, URLResponse) {
                let body = #"""
                [{"stationuuid":"u1","name":" Jazz FM ","url_resolved":"https://jazz.example/live","homepage":"https://jazz.example",
                  "favicon":"","country":"Norway","codec":"MP3","bitrate":128,"votes":40},
                 {"stationuuid":"u2","name":"Broken","url_resolved":"","url":"not a url"}]
                """#
                guard let url = request.url,
                      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
                else { throw URLError(.badURL) }
                return (Data(body.utf8), response)
            }
        }
        let results = try await RadioBrowser(transport: Directory()).search(name: "jazz", country: "")
        #expect(results.map(\.id) == ["u1"])
        #expect(results.first?.form.name == "Jazz FM")
        let request = try #require(RadioBrowser.request(name: "jazz", country: "Norway"))
        let items = try URLComponents(url: #require(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "limit", value: "30")))
        #expect(items.contains(URLQueryItem(name: "country", value: "Norway")))
    }
}

/// Writes a canned body to a temporary file, as URLSession's download would.
struct FakeDownloader: FileDownloading {
    let body: Data
    let mimeType: String

    func download(_ request: URLRequest, policy _: MediaRequestPolicy) async throws -> (URL, URLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try body.write(to: file)
        let response = URLResponse(
            url: url,
            mimeType: mimeType,
            expectedContentLength: body.count,
            textEncodingName: nil
        )
        return (file, response)
    }
}

@MainActor
struct DownloadManagerTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "DownloadTests-\(UUID())")

    func manager(_ downloader: FakeDownloader, database: AppDatabase? = nil) async throws -> DownloadManager {
        let database = try database ?? AppDatabase.inMemory()
        try? await TestData.saveServer(in: database, id: "s1")
        let manager = try DownloadManager(
            client: RecordingTransport().client(),
            database: database,
            serverID: "s1",
            directory: directory,
            downloader: downloader,
            settings: AppSettings(defaults: #require(UserDefaults(suiteName: "Downloads-\(UUID())"))),
            streamSettings: { StreamSettings() },
            isOnConstrainedNetwork: { false },
            now: { Date(timeIntervalSince1970: 0) }
        )
        await manager.load()
        return manager
    }

    @Test
    func `a downloaded track is stored, indexed and played from disk`() async throws {
        let downloads = try await manager(FakeDownloader(body: Data("fLaC".utf8), mimeType: "audio/flac"))
        let song = Song(id: "42", title: "Answer", suffix: "flac")
        downloads.download([song], from: .init(playlistID: "p", playlistName: "Mix"))
        await downloads.settled()

        let record = try #require(downloads.records["42"])
        #expect(record.fileName == "42.flac")
        #expect(record.size == 4)
        #expect(record.playlistName == "Mix")
        let file = try #require(downloads.index.fileURL(forSong: "42"))
        #expect(try Data(contentsOf: file) == Data("fLaC".utf8))

        await downloads.delete(["42"])
        #expect(downloads.records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test
    func `a Subsonic error instead of audio fails the download`() async throws {
        let downloads = try await manager(FakeDownloader(
            body: TestData.failure(code: 70),
            mimeType: "application/json"
        ))
        downloads.download([Song(id: "1", title: "Gone")])
        await downloads.settled()
        #expect(downloads.records.isEmpty)
        #expect(downloads.errorMessage?.contains("Gone") == true)
    }

    @Test
    func `downloads reload at sign-in, dropping rows whose file is gone`() async throws {
        let database = try AppDatabase.inMemory()
        let first = try await manager(FakeDownloader(body: Data("x".utf8), mimeType: "audio/mpeg"), database: database)
        first.download([Song(id: "a", suffix: "mp3"), Song(id: "b", suffix: "mp3")])
        await first.settled()
        try FileManager.default.removeItem(at: #require(first.index.fileURL(forSong: "b")))

        let second = try await manager(FakeDownloader(body: Data(), mimeType: "audio/mpeg"), database: database)
        await second.load()
        #expect(Set(second.records.keys) == ["a"])
        #expect(second.index.fileURL(forSong: "a") != nil)
    }

    @Test
    func `file names from server ids are safe`() {
        #expect(DownloadManager.safeName("abc-123_X") == "abc-123_X")
        #expect(DownloadManager.safeName("../../etc").count == 64)
        #expect(DownloadManager.safeSuffix("FLAC") == "flac")
        #expect(DownloadManager.safeSuffix("../sh") == "audio")
        #expect(DownloadManager.safeSuffix(nil) == "audio")
    }
}

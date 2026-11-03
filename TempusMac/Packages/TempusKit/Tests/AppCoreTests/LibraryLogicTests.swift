@testable import AppCore
import Foundation
import Persistence
import SubsonicAPI
import Synchronization
import Testing

/// Answers Subsonic methods from canned bodies (or fails them), and records every request.
final class RecordingTransport: HTTPTransport {
    enum Answer: Sendable {
        case body(Data)
        case offline
        case status(Int)
    }

    private let state: Mutex<(answers: [String: Answer], requests: [URL])>

    init(_ answers: [String: Answer] = [:]) {
        state = Mutex((answers, []))
    }

    var requests: [URL] {
        state.withLock { $0.requests }
    }

    func methods() -> [String] {
        requests.map(\.lastPathComponent)
    }

    func query(_ method: String) -> [URLQueryItem] {
        guard let url = requests.last(where: { $0.lastPathComponent == method }) else { return [] }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }

    func set(_ method: String, _ answer: Answer) {
        state.withLock { $0.answers[method] = answer }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        let method = url.lastPathComponent
        let answer = state.withLock { state -> Answer in
            state.requests.append(url)
            return state.answers[method] ?? .body(Self.ok)
        }
        let (data, status): (Data, Int)
        switch answer {
        case let .body(body): (data, status) = (body, 200)
        case let .status(code): (data, status) = (Data(), code)
        case .offline: throw URLError(.notConnectedToInternet)
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }

    static let ok = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)

    static func ok(_ payload: String) -> Answer {
        .body(Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1",\#(payload)}}"#.utf8))
    }

    func client() throws -> SubsonicClient {
        try SubsonicClient(
            server: ServerAddress(TestData.address),
            auth: SubsonicAuth(username: "alice", credential: .plaintext(password: "pw")),
            transport: self
        )
    }
}

struct HomeLayoutTests {
    @Test
    func `defaults show the upstream sections and keep the rest hidden`() {
        let layout = HomeLayout(stored: nil)
        #expect(layout.visible.first == .continueListening)
        #expect(layout.hidden.contains(.genres))
        #expect(Set(layout.visible).union(layout.hidden) == Set(HomeSection.allCases))
    }

    @Test
    func `stored layouts ignore unknown and repeated names`() {
        let layout = HomeLayout(stored: ["discover", "fromTheFuture", "discover", "playlists"])
        #expect(layout.visible == [.discover, .playlists])
    }

    @Test
    func `moving, hiding and showing sections`() {
        let layout = HomeLayout(visible: [.discover, .recentlyPlayed, .playlists])
        #expect(layout.moving(fromOffsets: [2], toOffset: 0).visible == [.playlists, .discover, .recentlyPlayed])
        #expect(layout.moving(fromOffsets: [0], toOffset: 3).visible == [.recentlyPlayed, .playlists, .discover])
        #expect(layout.hiding(.discover).visible == [.recentlyPlayed, .playlists])
        #expect(layout.showing(.genres).visible.last == .genres)
        #expect(layout.showing(.discover) == layout)
    }

    @MainActor @Test
    func `settings persist the layout and choices`() throws {
        let defaults = try #require(UserDefaults(suiteName: "HomeLayoutTests-\(UUID())"))
        let settings = AppSettings(defaults: defaults)
        #expect(settings.scrobbles)
        #expect(!settings.syncsPlayQueue)
        settings.setHomeLayout(HomeLayout(visible: [.genres]))
        settings.playlistSort = .songCount
        settings.setMusicFolderID("2", server: "s1")
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.homeLayout.visible == [.genres])
        #expect(reloaded.playlistSort == .songCount)
        #expect(reloaded.musicFolderID(server: "s1") == "2")
        #expect(reloaded.musicFolderID(server: "s2") == nil)
    }
}

struct PlaylistSortTests {
    static func playlist(_ id: String, _ name: String, songs: Int = 0, created: TimeInterval = 0) throws -> Playlist {
        let date = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: created))
        let json = #"{"id":"\#(id)","name":"\#(name)","songCount":\#(songs),"created":"\#(date)"}"#
        return try JSONDecoder().decode(Playlist.self, from: Data(json.utf8))
    }

    @Test
    func `sorts by name, count, date and faves`() throws {
        let lists = try [
            Self.playlist("1", "beta", songs: 5, created: 100),
            Self.playlist("2", "Alpha", songs: 9, created: 50),
            Self.playlist("3", "gamma", songs: 5, created: 300),
        ]
        #expect(PlaylistSort.name.sorted(lists).map(\.id) == ["2", "1", "3"])
        #expect(PlaylistSort.songCount.sorted(lists).map(\.id) == ["2", "1", "3"])
        #expect(PlaylistSort.dateCreated.sorted(lists).map(\.id) == ["3", "1", "2"])
        #expect(PlaylistSort.faves.sorted(lists, faves: ["3"]).map(\.id) == ["3", "2", "1"])
        #expect(Set(PlaylistSort.random.sorted(lists).map(\.id)) == ["1", "2", "3"])
    }
}

struct PlaylistServiceTests {
    func service(_ transport: RecordingTransport) async throws -> PlaylistService {
        let database = try AppDatabase.inMemory()
        try await TestData.saveServer(in: database, id: "s1")
        return try PlaylistService(
            client: transport.client(),
            pins: PinnedPlaylistStore(database: database),
            serverID: "s1"
        )
    }

    @Test
    func `saving replaces every track the server had with the edited list`() async throws {
        let transport = RecordingTransport()
        try await service(transport).save(
            playlistID: "p1", name: " Road Trip ", serverCount: 3,
            songs: [TestData.song("c"), TestData.song("a")]
        )
        let query = transport.query("updatePlaylist")
        #expect(query.filter { $0.name == "songIndexToRemove" }.map(\.value) == ["0", "1", "2"])
        #expect(query.filter { $0.name == "songIdToAdd" }.map(\.value) == ["c", "a"])
        #expect(query.first { $0.name == "name" }?.value == "Road Trip")
    }

    @Test
    func `an edit that would leave the playlist empty is refused`() async throws {
        let transport = RecordingTransport()
        await #expect(throws: PlaylistEditError.wouldBeEmpty) {
            try await service(transport).save(playlistID: "p1", name: "X", serverCount: 2, songs: [])
        }
        #expect(transport.requests.isEmpty)
    }

    @Test
    func `faves are kept locally`() async throws {
        let service = try await service(RecordingTransport())
        await service.setFave(true, playlistID: "p2")
        #expect(await service.faves() == ["p2"])
        await service.setFave(false, playlistID: "p2")
        #expect(await service.faves().isEmpty)
    }
}

@MainActor
struct StarServiceTests {
    func service(_ transport: RecordingTransport) async throws -> (StarService, PendingStarStore) {
        let database = try AppDatabase.inMemory()
        try await TestData.saveServer(in: database, id: "s1")
        let pending = PendingStarStore(database: database)
        let service = try StarService(client: transport.client(), pending: pending, serverID: "s1", now: { Date() })
        return (service, pending)
    }

    @Test
    func `starring shows at once and is sent to the server`() async throws {
        let transport = RecordingTransport()
        let (stars, _) = try await service(transport)
        let song = TestData.song("7")
        await stars.toggle(song)
        #expect(stars.isStarred(song))
        #expect(transport.query("star").first { $0.name == "id" }?.value == "7")
        #expect(stars.revision == 1)
    }

    @Test
    func `offline stars are queued and sent at the next sign-in`() async throws {
        let transport = RecordingTransport(["star": .offline])
        let (stars, pending) = try await service(transport)
        await stars.toggle(TestData.song("7"))
        #expect(stars.isStarred(TestData.song("7")))
        #expect(try await pending.pending(server: "s1").count == 1)

        transport.set("star", .body(RecordingTransport.ok))
        await stars.sendPending()
        #expect(try await pending.pending(server: "s1").isEmpty)
    }

    @Test
    func `a star the server refuses is undone with a message`() async throws {
        let transport = RecordingTransport([
            "star": .body(TestData.failure(code: 50)),
        ])
        let (stars, pending) = try await service(transport)
        await stars.toggle(TestData.song("7"))
        #expect(!stars.isStarred(TestData.song("7")))
        #expect(stars.errorMessage != nil)
        #expect(try await pending.pending(server: "s1").isEmpty)
    }

    @Test
    func `ratings are clamped and sent`() async throws {
        let transport = RecordingTransport()
        let (stars, _) = try await service(transport)
        await stars.setRating(9, for: TestData.song("7"))
        #expect(stars.rating(of: TestData.song("7")) == 5)
        #expect(transport.query("setRating").first { $0.name == "rating" }?.value == "5")
    }
}

struct ResumePolicyTests {
    @Test
    func `podcasts, audiobooks and long music keep their spot`() {
        #expect(ResumePolicy.keepsSpot(Song(id: "1", duration: 60, type: "podcast")))
        #expect(ResumePolicy.keepsSpot(Song(id: "2", duration: 60, type: "audiobook")))
        #expect(ResumePolicy.keepsSpot(Song(id: "3", duration: 601)))
        #expect(!ResumePolicy.keepsSpot(Song(id: "4", duration: 600)))
        #expect(!ResumePolicy.keepsSpot(Song(id: "5", duration: 9999, type: "radio")))
    }

    @Test
    func `the last ten seconds count as played through`() {
        #expect(ResumePolicy.isFinished(position: 591, duration: 600))
        #expect(!ResumePolicy.isFinished(position: 580, duration: 600))
        #expect(!ResumePolicy.isFinished(position: 5, duration: 0))
    }
}

struct PlaybackSourcesTests {
    @Test
    func `folder playback collects nested tracks and skips videos`() async throws {
        let transport = RecordingTransport()
        transport.set("getMusicDirectory", RecordingTransport.ok(#"""
        "directory":{"id":"root","child":[
          {"id":"a","isDir":false,"title":"A"},
          {"id":"v","isDir":false,"isVideo":true,"title":"Video"},
          {"id":"root","isDir":true,"title":"Loop"}
        ]}
        """#))
        let songs = try await PlaybackSources(client: transport.client()).songs(inFolder: "root")
        #expect(songs.map(\.id) == ["a"]) // the self-reference is visited once
    }

    @Test
    func `instant mix plays the song again, then similar ones`() async throws {
        let transport = RecordingTransport([
            "getSimilarSongs": RecordingTransport.ok(#""similarSongs":{"song":[{"id":"1"},{"id":"9"}]}"#),
        ])
        let mix = try await PlaybackSources(client: transport.client()).instantMix(for: TestData.song("1"))
        #expect(mix.map(\.id) == ["1", "9"])
    }

    @Test
    func `podcast episodes play only once the server has them`() throws {
        func episode(_ status: String) throws -> PodcastEpisode {
            try JSONDecoder().decode(
                PodcastEpisode.self,
                from: Data(#"{"id":"e","streamId":"s","title":"Ep","status":"\#(status)"}"#.utf8)
            )
        }
        #expect(try episode("completed").song(channelTitle: "Show")?.id == "s")
        #expect(try episode("completed").song(channelTitle: "Show")?.type == "podcast")
        #expect(try episode("skipped").song(channelTitle: "Show") == nil)
    }

    @MainActor @Test
    func `features hide only on a definite not implemented`() async throws {
        let transport = RecordingTransport(["getPodcasts": .status(501), "getShares": .offline])
        let features = try ServerFeatures(client: transport.client())
        await features.probe()
        #expect(!features.hasPodcasts)
        #expect(features.hasShares)
    }
}

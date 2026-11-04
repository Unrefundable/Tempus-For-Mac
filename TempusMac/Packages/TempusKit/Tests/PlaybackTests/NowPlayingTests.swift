import Foundation
import MediaPlayer
@testable import Playback
import SubsonicAPI
import Testing

@MainActor
final class FakeNowPlaying: NowPlayingPublishing {
    private(set) var snapshots: [NowPlayingSnapshot?] = []

    func publish(_ snapshot: NowPlayingSnapshot?) {
        snapshots.append(snapshot)
    }
}

@MainActor
@Suite("Now Playing")
struct NowPlayingTests {
    @Test("Follows the track and pause state; the rate is 0 while paused so the clock stops")
    func follows() throws {
        let engine = FakeEngine()
        let defaults = try #require(UserDefaults(suiteName: "NowPlayingTests-\(UUID().uuidString)"))
        let player = PlayerController(
            engine: engine, source: FakeSource(), queueSaver: nil, serverID: "srv",
            settingsStore: PlaybackSettingsStore(defaults: defaults),
            environment: .test(now: Date())
        )
        let nowPlaying = FakeNowPlaying()
        player.setNowPlaying(nowPlaying)
        #expect(nowPlaying.snapshots == [nil])

        try player.play([song("a"), song("b")], startingAt: 1)
        engine.send(.stateChanged(.playing))
        let playing = try #require(nowPlaying.snapshots.last ?? nil)
        #expect(playing.song.id == "b")
        #expect(playing.rate == 1)
        #expect(playing.queueIndex == 1)
        #expect(playing.queueCount == 2)

        player.pause()
        #expect(nowPlaying.snapshots.last??.rate == 0)
        #expect(nowPlaying.snapshots.last??.status == .paused)
    }

    @Test("Streams come from the server with its custom headers")
    func subsonicSource() throws {
        let client = try SubsonicClient(
            server: ServerAddress("https://music.example.com"),
            auth: SubsonicAuth(username: "alice", credential: .token(token: "t", salt: "s")),
            headers: CustomHeaders(parsing: "CF-Access-Client-Id: abc")
        )
        let item = try QueueItem(song: song("s1"))

        let stream = try SubsonicStreamSource(client: client)
            .streamItem(for: item, quality: .transcoded(format: "mp3", maxBitrate: 192))
        let query = try #require(URLComponents(url: stream.url, resolvingAgainstBaseURL: false)?.queryItems)

        #expect(stream.id == item.id)
        #expect(stream.url.path == "/rest/stream")
        #expect(query.contains(URLQueryItem(name: "id", value: "s1")))
        #expect(query.contains(URLQueryItem(name: "format", value: "mp3")))
        #expect(stream.headers == ["CF-Access-Client-Id": "abc"])
    }

    @Test("Each status maps to the system's playback state", arguments: [
        (PlaybackStatus.playing, MPNowPlayingPlaybackState.playing),
        (.buffering, .playing),
        (.paused, .paused),
        (.stopped, .stopped),
    ])
    func playbackState(status: PlaybackStatus, expected: MPNowPlayingPlaybackState) {
        #expect(SystemNowPlaying.playbackState(for: status) == expected)
    }

    @Test("A queue restored paused claims the media keys once, by reporting playing first")
    func claimsMediaKeysOnce() {
        #expect(SystemNowPlaying.claimsMediaKeys(reporting: .paused, hasClaimed: false))
        #expect(!SystemNowPlaying.claimsMediaKeys(reporting: .paused, hasClaimed: true))
        // Really playing claims them anyway, and nothing is left to claim with nothing queued.
        #expect(!SystemNowPlaying.claimsMediaKeys(reporting: .playing, hasClaimed: false))
        #expect(!SystemNowPlaying.claimsMediaKeys(reporting: .stopped, hasClaimed: false))
    }

    @Test("Only playing or the claim itself counts as having claimed the media keys", arguments: [
        (PlaybackStatus.stopped, false),
        (.paused, true),
        (.playing, true),
        (.buffering, true),
    ])
    func claimSticks(status: PlaybackStatus, claimed: Bool) {
        #expect(SystemNowPlaying.hasClaimedMediaKeys(after: status, hadClaimed: false) == claimed)
        #expect(SystemNowPlaying.hasClaimedMediaKeys(after: status, hadClaimed: true))
    }

    @Test("The system dictionary carries the track's details and timing")
    func dictionary() throws {
        let snapshot = try NowPlayingSnapshot(
            song: song("a", album: "Album", duration: 180),
            position: 12, duration: 180, rate: 1, status: .playing, queueIndex: 0, queueCount: 3
        )
        let info = SystemNowPlaying.info(for: snapshot)

        #expect(info[MPMediaItemPropertyTitle] as? String == "Song a")
        #expect(info[MPMediaItemPropertyAlbumTitle] as? String == "Album")
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? TimeInterval == 180)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval == 12)
        #expect(info[MPNowPlayingInfoPropertyPlaybackQueueCount] as? Int == 3)
    }
}

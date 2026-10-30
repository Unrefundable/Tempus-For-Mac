// swiftlint:disable no_print
// Diagnostic output for a person running these tests by hand; os.Logger would not reach the terminal.

import Foundation
@testable import Playback
import SubsonicAPI
import Testing

/// Streams real tracks from the server `scripts/live-test.sh` asks for, with the volume at zero.
/// Read-only: plays are reported as events but nothing is scrobbled or saved.
@MainActor
@Suite(
    "Live playback (silent)",
    .enabled(if: ProcessInfo.processInfo.environment["TEMPUS_LIVE_SERVER"] != nil),
    .serialized
)
struct LivePlaybackTests {
    private static let timeout: TimeInterval = 20

    private func client() throws -> SubsonicClient {
        let environment = ProcessInfo.processInfo.environment
        let password = try #require(environment["TEMPUS_LIVE_PASSWORD"])
        let credential: SubsonicCredential = environment["TEMPUS_LIVE_PLAINTEXT"] == "1"
            ? .plaintext(password: password)
            : .tokenized(password: password)
        return try SubsonicClient(
            server: ServerAddress(#require(environment["TEMPUS_LIVE_SERVER"])),
            auth: SubsonicAuth(username: #require(environment["TEMPUS_LIVE_USER"]), credential: credential)
        )
    }

    /// Waits, letting the main queue run AudioStreaming's callbacks, until `condition` holds.
    private func wait(for what: String, _ condition: () -> Bool) async throws {
        let deadline = Date() + Self.timeout
        while !condition() {
            guard Date() < deadline else {
                Issue.record("Timed out waiting for \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    @Test("Random tracks stream, decode, seek, and move on to the next one")
    func streams() async throws {
        let client = try client()
        let songs = try await client.send(.randomSongs(size: 2))
        try #require(songs.count == 2, "The server needs at least two songs")
        for song in songs {
            print("  - \(song.suffix ?? "?") \(song.bitrate.map { "\($0) kbps" } ?? ""), \(song.duration ?? 0) s")
        }

        let engine = StreamingEngine(policy: client.mediaRequestPolicy)
        engine.volume = 0
        let defaults = try #require(UserDefaults(suiteName: "LivePlaybackTests-\(UUID().uuidString)"))
        let player = PlayerController(
            engine: engine,
            source: SubsonicStreamSource(client: client),
            queueSaver: nil,
            serverID: "live",
            settingsStore: PlaybackSettingsStore(defaults: defaults)
        )

        player.play(songs)
        try await wait(for: "the first track to play") { player.status == .playing && player.position > 1 }
        #expect(player.errorMessage == nil)

        let first = try #require(player.queue.current)
        player.seek(to: max(0, player.duration - 3))
        try await wait(for: "the second track to start") { player.queue.current?.id != first.id }
        #expect(player.queue.current?.song.id == songs[1].id)
        try await wait(for: "the second track to play") { player.status == .playing && player.position > 0.5 }

        player.stop()
        print("  - Played, sought and moved on to the next track")
    }
}

// swiftlint:enable no_print

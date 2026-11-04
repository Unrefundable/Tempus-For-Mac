@testable import AppCore
import Darwin
import Foundation
import Playback
import SubsonicAPI
import Testing

struct DiscordFrameTests {
    @Test
    func `frames start with a little-endian opcode and length`() {
        let frame = DiscordFrame(opcode: .frame, payload: Data("{}".utf8))
        #expect([UInt8](frame.encoded()) == [1, 0, 0, 0, 2, 0, 0, 0, 0x7B, 0x7D])
    }

    @Test
    func `a whole frame decodes, with the bytes it used`() throws {
        let frame = DiscordFrame(opcode: .close, payload: Data(#"{"code":4000}"#.utf8))
        let buffer = frame.encoded() + Data([9, 9])
        let decoded = try #require(try DiscordFrame.decode(buffer))
        #expect(decoded.frame == frame)
        #expect(decoded.length == buffer.count - 2)
    }

    @Test
    func `a partial frame waits for more bytes`() throws {
        let encoded = DiscordFrame(opcode: .frame, payload: Data("hello".utf8)).encoded()
        #expect(try DiscordFrame.decode(encoded.prefix(4)) == nil)
        #expect(try DiscordFrame.decode(encoded.prefix(10)) == nil)
    }

    @Test
    func `unknown opcodes and oversized frames are rejected`() {
        #expect(throws: DiscordIPCError.malformedFrame) {
            try DiscordFrame.decode(Data([9, 0, 0, 0, 0, 0, 0, 0]))
        }
        #expect(throws: DiscordIPCError.malformedFrame) {
            try DiscordFrame.decode(Data([1, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0x7F]))
        }
    }

    @Test
    func `the handshake names the application`() throws {
        let frame = try DiscordFrame.handshake(clientID: "1234")
        #expect(frame.opcode == .handshake)
        let json = try #require(JSONSerialization.jsonObject(with: frame.payload) as? [String: Any])
        #expect(json["v"] as? Int == 1)
        #expect(json["client_id"] as? String == "1234")
    }

    @Test
    func `setting an activity sends a listening status with its times in milliseconds`() throws {
        let activity = DiscordActivity(
            songID: "s1", details: "Song", state: "Artist",
            start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 300)
        )
        let frame = try DiscordFrame.setActivity(activity, pid: 42, nonce: "n")
        let json = try #require(JSONSerialization.jsonObject(with: frame.payload) as? [String: Any])
        #expect(json["cmd"] as? String == "SET_ACTIVITY")
        #expect(json["nonce"] as? String == "n")
        let args = try #require(json["args"] as? [String: Any])
        #expect(args["pid"] as? Int == 42)
        let sent = try #require(args["activity"] as? [String: Any])
        #expect(sent["type"] as? Int == 2)
        #expect(sent["details"] as? String == "Song")
        #expect(sent["state"] as? String == "Artist")
        let times = try #require(sent["timestamps"] as? [String: Any])
        #expect(times["start"] as? Int == 100_000)
        #expect(times["end"] as? Int == 300_000)
    }

    @Test
    func `clearing sends no activity`() throws {
        let frame = try DiscordFrame.setActivity(nil, pid: 42, nonce: "n")
        let json = try #require(JSONSerialization.jsonObject(with: frame.payload) as? [String: Any])
        let args = try #require(json["args"] as? [String: Any])
        #expect(args["activity"] == nil)
        #expect(args["pid"] as? Int == 42)
    }
}

struct DiscordSocketPathTests {
    @Test
    func `the temporary folder is named from the account's UUID and user ID`() {
        #expect(
            DiscordSocketConnection.temporaryFolder(uuid: [UInt8](repeating: 0, count: 16), uid: 503)
                == "/var/folders/00/0000000000000000000000000000gq/T/"
        )
        #expect(
            DiscordSocketConnection.temporaryFolder(uuid: Array(0 ..< 16), uid: 501)
                == "/var/folders/00/0h40r40m30f209185hr38f1w0000gn/T/"
        )
    }

    @Test
    func `the computed folder is the one the system reports outside the sandbox`() throws {
        var bytes = [CChar](repeating: 0, count: Int(PATH_MAX))
        try #require(confstr(_CS_DARWIN_USER_TEMP_DIR, &bytes, bytes.count) > 0)
        let reported = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #expect(DiscordSocketConnection.accountTemporaryFolder() == reported)
    }

    @Test
    func `only the account's folder is tried, since the sandbox allows nothing else`() throws {
        let folder = try #require(DiscordSocketConnection.accountTemporaryFolder())
        #expect(DiscordSocketConnection.candidatePaths() == (0 ..< 10).map { folder + "discord-ipc-\($0)" })
    }

    @Test
    func `Discord's messages are cleaned and shortened before they're shown`() {
        #expect(DiscordSocketConnection.sanitized("Invalid\u{0007} Client ID\n") == "Invalid Client ID")
        #expect(DiscordSocketConnection.sanitized(String(repeating: "x", count: 500))?.count == 201)
        #expect(DiscordSocketConnection.sanitized("\n\t") == nil)
        #expect(DiscordSocketConnection.sanitized(nil) == nil)
    }
}

struct DiscordActivityTests {
    private let now = Date(timeIntervalSince1970: 1000)

    private func snapshot(
        _ song: Song = Song(id: "s1", title: "Title", artist: "Artist", duration: 200),
        status: PlaybackStatus = .playing,
        position: TimeInterval = 50,
        rate: Double = 1
    ) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            song: song, position: position, duration: 200, rate: status == .playing ? rate : 0,
            status: status, queueIndex: 0, queueCount: 1
        )
    }

    @Test
    func `a playing track shows its title, artist and remaining time`() throws {
        let activity = try #require(DiscordActivity(snapshot: snapshot(), now: now))
        #expect(activity.details == "Title")
        #expect(activity.state == "Artist")
        #expect(activity.start == Date(timeIntervalSince1970: 950))
        #expect(activity.end == Date(timeIntervalSince1970: 1150))
    }

    @Test
    func `faster playback makes the times shorter`() throws {
        let activity = try #require(DiscordActivity(snapshot: snapshot(rate: 2), now: now))
        #expect(activity.start == Date(timeIntervalSince1970: 975))
        #expect(activity.end == Date(timeIntervalSince1970: 1075))
    }

    @Test(arguments: [PlaybackStatus.paused, .stopped])
    func `nothing shows unless playing`(status: PlaybackStatus) {
        #expect(DiscordActivity(snapshot: snapshot(status: status), now: now) == nil)
        #expect(DiscordActivity(snapshot: nil, now: now) == nil)
    }

    @Test
    func `buffering shows the track without times`() throws {
        let activity = try #require(DiscordActivity(snapshot: snapshot(status: .buffering), now: now))
        #expect(activity.details == "Title")
        #expect(activity.start == nil)
        #expect(activity.end == nil)
    }

    @Test
    func `text fits Discord's two to 128 characters`() throws {
        let long = String(repeating: "a", count: 300)
        let activity = try #require(DiscordActivity(
            snapshot: snapshot(Song(id: "s", title: "X", artist: long)), now: now
        ))
        #expect(activity.details.count == 2)
        #expect(activity.details.hasPrefix("X"))
        #expect(try #require(activity.state).utf16.count == 128)
        #expect(try #require(activity.state).hasSuffix("…"))
    }

    @Test
    func `unknown or endless durations and positions show no times instead of crashing`() throws {
        let song = Song(id: "s1", title: "Title", artist: "Artist")
        let endless = NowPlayingSnapshot(
            song: song, position: 30, duration: .infinity, rate: 1, status: .playing, queueIndex: 0, queueCount: 1
        )
        let streaming = try #require(DiscordActivity(snapshot: endless, now: now))
        #expect(streaming.start == Date(timeIntervalSince1970: 970))
        #expect(streaming.end == nil)
        let unknown = NowPlayingSnapshot(
            song: song, position: .nan, duration: .nan, rate: 1, status: .playing, queueIndex: 0, queueCount: 1
        )
        let loading = try #require(DiscordActivity(snapshot: unknown, now: now))
        #expect(loading.start == nil)
        #expect(loading.end == nil)
        _ = try DiscordFrame.setActivity(streaming, pid: 1, nonce: "n")
    }

    @Test
    func `untitled tracks still have details and no artist means no state`() throws {
        let activity = try #require(DiscordActivity(snapshot: snapshot(Song(id: "s")), now: now))
        #expect(activity.details == "Unknown track")
        #expect(activity.state == nil)
    }

    @Test
    func `the same track a moment later is similar, another track or a seek is not`() throws {
        let first = try #require(DiscordActivity(snapshot: snapshot(position: 50), now: now))
        let later = try #require(DiscordActivity(
            snapshot: snapshot(position: 51), now: now.addingTimeInterval(1.5)
        ))
        let seeked = try #require(DiscordActivity(snapshot: snapshot(position: 120), now: now))
        let other = try #require(DiscordActivity(
            snapshot: snapshot(Song(id: "s2", title: "Title", artist: "Artist")), now: now
        ))
        #expect(first.isSimilar(to: later))
        #expect(!first.isSimilar(to: seeked))
        #expect(!first.isSimilar(to: other))
    }
}

@MainActor
struct DiscordPresenceTests {
    private let defaults: UserDefaults
    private let settings: AppSettings
    private let connection = FakeDiscordConnection()
    private var presence: DiscordPresence!

    init() throws {
        defaults = try #require(UserDefaults(suiteName: "DiscordPresenceTests-\(UUID())"))
        settings = AppSettings(defaults: defaults)
        let connection = connection
        presence = DiscordPresence(
            settings: settings,
            makeConnection: { connection },
            now: { Date(timeIntervalSince1970: 1000) },
            debounce: .zero,
            retryDelay: .seconds(3600)
        )
    }

    private func playing(_ id: String = "s1", status: PlaybackStatus = .playing) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            song: Song(id: id, title: "Song \(id)", artist: "Artist", duration: 200),
            position: 10, duration: 200, rate: status == .playing ? 1 : 0,
            status: status, queueIndex: 0, queueCount: 1
        )
    }

    /// Connecting always introduces Tempus as its own Discord application.
    private static let opened = FakeDiscordConnection.Event.open(DiscordPresence.applicationID)

    private func enable() async {
        settings.sharesNowPlayingOnDiscord = true
        presence.refresh()
        await presence.settled()
    }

    @Test
    func `nothing is sent while the setting is off`() async {
        presence.publish(playing())
        await presence.settled()
        #expect(await connection.events.isEmpty)
        #expect(presence.status == .off)
    }

    @Test
    func `playing connects with the application ID and shows the track`() async {
        await enable()
        presence.publish(playing())
        await presence.settled()
        #expect(await connection.events == [Self.opened, .set("s1")])
        #expect(presence.status == .connected)
    }

    @Test
    func `nothing playing doesn't connect at all`() async {
        await enable()
        presence.publish(nil)
        await presence.settled()
        #expect(await connection.events.isEmpty)
    }

    @Test
    func `pausing clears the status and the same track again isn't resent`() async {
        await enable()
        presence.publish(playing())
        await presence.settled()
        presence.publish(playing())
        await presence.settled()
        presence.publish(playing(status: .paused))
        await presence.settled()
        #expect(await connection.events == [Self.opened, .set("s1"), .set(nil)])
    }

    @Test
    func `turning it off clears the status and disconnects`() async {
        await enable()
        presence.publish(playing())
        await presence.settled()
        settings.sharesNowPlayingOnDiscord = false
        presence.refresh()
        await presence.settled()
        #expect(await connection.events == [Self.opened, .set("s1"), .set(nil), .close])
        #expect(presence.status == .off)
    }

    @Test
    func `when Discord isn't running it says so, then tries again when asked`() async {
        await connection.failOpens(true)
        await enable()
        presence.publish(playing())
        await presence.settled()
        #expect(presence.status == .unavailable(DiscordIPCError.discordNotRunning.message))
        await connection.failOpens(false)
        presence.refresh()
        await presence.settled()
        #expect(await connection.events == [Self.opened, Self.opened, .set("s1")])
        #expect(presence.status == .connected)
    }

    @Test
    func `a failed update drops the connection and reconnects next time`() async {
        await enable()
        presence.publish(playing())
        await presence.settled()
        await connection.failSets(true)
        presence.publish(playing("s2"))
        await presence.settled()
        await connection.failSets(false)
        presence.refresh()
        await presence.settled()
        #expect(await connection.events == [
            Self.opened, .set("s1"), .set("s2"), .close, Self.opened, .set("s2"),
        ])
    }

}

actor FakeDiscordConnection: DiscordConnection {
    enum Event: Equatable {
        case open(String)
        case set(String?)
        case close
    }

    private(set) var events: [Event] = []
    private var opensFail = false
    private var setsFail = false

    func failOpens(_ fail: Bool) {
        opensFail = fail
    }

    func failSets(_ fail: Bool) {
        setsFail = fail
    }

    func open(clientID: String) throws(DiscordIPCError) {
        events.append(.open(clientID))
        if opensFail {
            throw .discordNotRunning
        }
    }

    func setActivity(_ activity: DiscordActivity?) throws(DiscordIPCError) {
        events.append(.set(activity?.songID))
        if setsFail {
            throw .connectionLost
        }
    }

    func close() {
        events.append(.close)
    }
}

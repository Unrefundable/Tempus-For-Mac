@testable import AppCore
import Foundation
import SubsonicAPI
import Synchronization
import Testing

/// A Navidrome stand-in for lyrics search: a library that pages, a scan marker, per-song lyrics,
/// songs whose lyrics the server refuses or can't be reached for, and listings that misbehave.
/// Records every method asked for.
final class FakeLyricsServer: HTTPTransport {
    struct Track: Sendable {
        var id: String
        var size: Int64 = 100
        var lyrics: String?
    }

    struct State: Sendable {
        var tracks: [Track] = []
        var lastScan: String? = "scan-1"
        var isScanning = false
        /// Songs whose lyrics the server answers with an error.
        var failing: Set<String> = []
        /// Songs whose lyrics requests never reach the server.
        var unreachable: Set<String> = []
        /// The most songs a listing page holds, whatever was asked.
        var pageCap = Int.max
        /// Listings come back empty, as from a server that doesn't list everything for an empty query.
        var listsNothing = false
        /// A scan starts as soon as the library is listed.
        var scansWhenListed = false
        var requests: [String] = []
    }

    let state: Mutex<State>

    init(_ tracks: [Track]) {
        state = Mutex(State(tracks: tracks))
    }

    var requests: [String] {
        state.withLock { $0.requests }
    }

    func update(_ change: (inout State) -> Void) {
        state.withLock { change(&$0) }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let method = url.lastPathComponent
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        let body = state.withLock { state -> String? in
            state.requests.append(method)
            // Songs are titled "Song <id>", which is how the getLyrics fallback names them.
            let lyricsSong = method == "getLyricsBySongId" ? value("id")
                : method == "getLyrics" ? value("title").map { String($0.dropFirst("Song ".count)) } : nil
            if let lyricsSong, state.unreachable.contains(lyricsSong) {
                return nil
            }
            defer {
                if method == "search3", state.scansWhenListed {
                    state.isScanning = true
                }
            }
            return Self.body(method: method, value: value, state: state)
        }
        guard let body else { throw URLError(.cannotConnectToHost) }
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        // A failure carries its own status; everything else is a success.
        let content = body.hasPrefix(#""status""#) ? body : #""status":"ok",\#(body)"#
        return (Data(#"{"subsonic-response":{"version":"1.16.1",\#(content)}}"#.utf8), response)
    }

    private static func body(method: String, value: (String) -> String?, state: State) -> String {
        switch method {
        case "getScanStatus":
            let lastScan = state.lastScan.map { #","lastScan":"\#($0)""# } ?? ""
            return #""scanStatus":{"scanning":\#(state.isScanning),"count":\#(state.tracks.count)\#(lastScan)}"#
        case "search3":
            let offset = Int(value("songOffset") ?? "0") ?? 0
            let count = min(Int(value("songCount") ?? "0") ?? 0, state.pageCap)
            let listed = state.listsNothing ? [] : state.tracks
            let page = listed.dropFirst(offset).prefix(count).map { track in
                #"{"id":"\#(track.id)","title":"Song \#(track.id)","artist":"A","isDir":false,"#
                    + #""size":\#(track.size),"path":"\#(track.id).flac"}"#
            }
            return #""searchResult3":{"song":[\#(page.joined(separator: ","))]}"#
        case "getLyricsBySongId":
            let id = value("id") ?? ""
            if state.failing.contains(id) {
                return #""status":"failed","error":{"code":0,"message":"boom"}"#
            }
            guard let lyrics = state.tracks.first(where: { $0.id == id })?.lyrics else { return #""lyricsList":{}"# }
            let lines = lyrics.split(separator: "\n").map { #"{"value":"\#($0)"}"# }.joined(separator: ",")
            return #""lyricsList":{"structuredLyrics":[{"lang":"eng","synced":false,"line":[\#(lines)]}]}"#
        default:
            // getLyrics, the fallback for songs without structured lyrics: nothing either, or
            // the same failure for a failing song (titled "Song <id>").
            let id = value("title").map { String($0.dropFirst("Song ".count)) } ?? ""
            if state.failing.contains(id) {
                return #""status":"failed","error":{"code":0,"message":"boom"}"#
            }
            return #""lyrics":{}"#
        }
    }
}

/// A clock tests move by hand.
final class TestClock: Sendable {
    private let current = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

    var now: Date {
        current.withLock { $0 }
    }

    func advance(days: Double) {
        advance(hours: days * 24)
    }

    func advance(hours: Double) {
        current.withLock { $0 += hours * 60 * 60 }
    }
}

/// A client whose requests go to `server`.
func fakeLyricsClient(_ server: FakeLyricsServer) throws -> SubsonicClient {
    try SubsonicClient(
        server: ServerAddress(TestData.address),
        auth: SubsonicAuth(username: "alice", credential: .plaintext(password: "pw")),
        transport: server
    )
}

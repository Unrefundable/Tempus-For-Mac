@testable import AppCore
import Foundation
import Persistence
import Playback
import SecureStorage
import SubsonicAPI
import Synchronization

enum TestData {
    static let address = "https://music.example.com"

    static func song(_ id: String, coverArtID: String? = nil) -> Song {
        Song(id: id, title: "Song \(id)", artist: "Artist", coverArtID: coverArtID, duration: 200)
    }

    @discardableResult
    static func saveServer(in database: AppDatabase, id: String = "server-1") async throws -> ServerProfile {
        let profile = try ServerProfile(
            id: id, name: "Home", username: "alice", address: ServerAddress(address), localAddress: nil,
            usesPlaintextPassword: false, createdAt: Date(timeIntervalSince1970: 0)
        )
        try await ServerStore(database: database).save(profile)
        return profile
    }

    static func form(
        name: String = "Home",
        address: String = address,
        username: String = "alice",
        password: String = "secret"
    ) -> ServerForm {
        var form = ServerForm()
        form.name = name
        form.address = address
        form.username = username
        form.password = password
        return form
    }

    static func validServer(_ form: ServerForm = form()) throws -> ValidServer {
        try form.validated().get()
    }

    static let pingResponse = Data(#"{"subsonic-response":{"status":"ok","version":"1.16.1"}}"#.utf8)

    static func failure(code: Int) -> Data {
        Data(#"{"subsonic-response":{"status":"failed","version":"1.16.1","error":{"code":\#(code)}}}"#.utf8)
    }
}

/// Keychain stand-in.
final class MemorySecretStore: SecretStore {
    private let items = Mutex<[String: Data]>([:])

    var keys: Set<String> {
        items.withLock { Set($0.keys) }
    }

    func data(for key: String) throws(SecretStoreError) -> Data? {
        items.withLock { $0[key] }
    }

    func set(_ data: Data, for key: String) throws(SecretStoreError) {
        items.withLock { $0[key] = data }
    }

    func removeData(for key: String) throws(SecretStoreError) {
        _ = items.withLock { $0.removeValue(forKey: key) }
    }
}

/// Answers every ping the same way and records which servers were asked.
final class PingStub: Sendable {
    private let state: Mutex<(results: [String: Result<ServerInfo, SubsonicError>], asked: [URL])>

    init(_ results: [String: Result<ServerInfo, SubsonicError>] = [:]) {
        state = Mutex((results, []))
    }

    var asked: [URL] {
        state.withLock { $0.asked }
    }

    func set(_ origin: String, _ result: Result<ServerInfo, SubsonicError>) {
        state.withLock { $0.results[origin] = result }
    }

    var tester: ConnectionTester {
        ConnectionTester { [self] client throws(SubsonicError) in
            let result = state.withLock { state -> Result<ServerInfo, SubsonicError> in
                state.asked.append(client.server.url)
                return state.results[client.server.url.absoluteString] ?? .success(Self.info)
            }
            return try result.get()
        }
    }

    static let info = ServerInfo(apiVersion: "1.16.1", type: "navidrome", serverVersion: "0.64.2", isOpenSubsonic: true)
}

/// Answers Subsonic methods from canned bodies.
struct StubTransport: HTTPTransport {
    let bodies: [String: Data]

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let method = request.url?.lastPathComponent ?? ""
        guard let url = request.url, let body = bodies[method],
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else { throw URLError(.cannotConnectToHost) }
        return (body, response)
    }
}

/// Records what the app asks of the engine.
@MainActor
final class FakeEngine: PolicySwitchingEngine {
    var onEvent: (@MainActor (EngineEvent) -> Void)?
    var progress: TimeInterval = 0
    var duration: TimeInterval = 0
    var volume: Float = 1
    private(set) var calls: [String] = []
    private(set) var policyServers: [URL?] = []

    func setPolicy(_ policy: MediaRequestPolicy?) {
        calls.append("setPolicy")
        policyServers.append(policy.map { _ in URL(string: "about:policy") } ?? nil)
    }

    func play(_: EngineItem) {
        calls.append("play")
    }

    func setUpcoming(_: EngineItem?) {}

    func pause() {
        calls.append("pause")
    }

    func resume() {
        calls.append("resume")
    }

    func stop() {
        calls.append("stop")
    }

    func seek(to _: TimeInterval) {}
    func apply(speed _: PlaybackSpeed) {}
    func apply(equalizer _: EqualizerSettings) {}
    func setGain(decibels _: Double) {}
}

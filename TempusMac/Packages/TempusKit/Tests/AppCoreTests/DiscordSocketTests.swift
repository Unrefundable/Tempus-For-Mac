@testable import AppCore
import Darwin
import Foundation
import Testing

/// The socket connection against a stand-in for the Discord app.
struct DiscordSocketTests {
    private static let ready = Data(#"{"cmd":"DISPATCH","evt":"READY"}"#.utf8)

    @Test
    func `connects, answers pings, skips other events and matches the status reply`() async throws {
        let server = try FakeDiscordServer { frame in
            switch frame.opcode {
            case .handshake:
                return [DiscordFrame(opcode: .frame, payload: Self.ready)]
            case .frame:
                let nonce = (try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any])?["nonce"]
                let reply = try? JSONSerialization.data(withJSONObject: ["cmd": "SET_ACTIVITY", "nonce": nonce ?? ""])
                return [
                    DiscordFrame(opcode: .ping, payload: Data("{}".utf8)),
                    DiscordFrame(opcode: .frame, payload: Data(#"{"evt":"ACTIVITY_JOIN","nonce":"other"}"#.utf8)),
                    DiscordFrame(opcode: .frame, payload: reply ?? Data()),
                ]
            default:
                return []
            }
        }
        let connection = DiscordSocketConnection(paths: ["/nonexistent/discord-ipc-0", server.path])
        try await connection.open(clientID: "123456789012345678")
        let activity = DiscordActivity(songID: "s", details: "Song", state: "Artist", start: nil, end: nil)
        try await connection.setActivity(activity)
        try await connection.setActivity(nil)
        await connection.close()
        #expect(server.received.map(\.opcode) == [.handshake, .frame, .pong, .frame, .pong])
    }

    @Test
    func `a refused application ID reports Discord's reason`() async throws {
        let server = try FakeDiscordServer { _ in
            [DiscordFrame(opcode: .close, payload: Data(#"{"code":4000,"message":"Invalid Client ID"}"#.utf8))]
        }
        let connection = DiscordSocketConnection(paths: [server.path])
        await #expect(throws: DiscordIPCError.rejected("Invalid Client ID")) {
            try await connection.open(clientID: "1")
        }
    }

    @Test
    func `a refused status reports Discord's reason`() async throws {
        let server = try FakeDiscordServer { frame in
            guard frame.opcode == .frame else { return [DiscordFrame(opcode: .frame, payload: Self.ready)] }
            let nonce = (try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any])?["nonce"]
            let reply = try? JSONSerialization.data(withJSONObject: [
                "evt": "ERROR", "nonce": nonce ?? "", "data": ["code": 4002, "message": "bad\nactivity"],
            ])
            return [DiscordFrame(opcode: .frame, payload: reply ?? Data())]
        }
        let connection = DiscordSocketConnection(paths: [server.path])
        try await connection.open(clientID: "123456789012345678")
        await #expect(throws: DiscordIPCError.rejected("badactivity")) {
            try await connection.setActivity(nil)
        }
    }

    @Test
    func `a Discord that never answers times out`() async throws {
        let server = try FakeDiscordServer { _ in [] }
        let connection = DiscordSocketConnection(paths: [server.path], timeout: .milliseconds(200))
        await #expect(throws: DiscordIPCError.timedOut) {
            try await connection.open(clientID: "123456789012345678")
        }
    }

    @Test
    func `no socket means Discord isn't running`() async {
        let connection = DiscordSocketConnection(paths: ["/nonexistent/discord-ipc-0"])
        await #expect(throws: DiscordIPCError.discordNotRunning) {
            try await connection.open(clientID: "123456789012345678")
        }
    }
}

/// Listens on a Unix socket, accepts one client and answers each frame it gets with `respond`.
private final class FakeDiscordServer: @unchecked Sendable {
    let path = "/tmp/tempus-discord-\(UUID().uuidString.prefix(8))"
    private let listener: Int32
    private let lock = NSLock()
    private var frames: [DiscordFrame] = []

    var received: [DiscordFrame] {
        lock.withLock { frames }
    }

    init(respond: @escaping @Sendable (DiscordFrame) -> [DiscordFrame]) throws {
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0 && listen(listener, 1) == 0)
        let listener = listener
        Thread.detachNewThread { [self] in
            serve(accept(listener, nil, nil), respond: respond)
        }
    }

    deinit {
        close(listener)
        unlink(path)
    }

    private func serve(_ client: Int32, respond: (DiscordFrame) -> [DiscordFrame]) {
        guard client >= 0 else { return }
        defer { close(client) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(client, $0.baseAddress, $0.count) }
            guard count > 0 else { return }
            buffer.append(contentsOf: chunk.prefix(count))
            while let (frame, length) = try? DiscordFrame.decode(buffer) {
                buffer = Data(buffer.dropFirst(length))
                lock.withLock { frames.append(frame) }
                for reply in respond(frame) {
                    let bytes = [UInt8](reply.encoded())
                    _ = bytes.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                }
            }
        }
    }
}

import Foundation

/// What can go wrong talking to the Discord app. `message` is safe to show.
public enum DiscordIPCError: Error, Equatable, Sendable {
    /// No Discord socket answered: Discord is closed, or the sandbox kept Tempus out.
    case discordNotRunning
    case connectionLost
    /// Discord didn't finish answering within the exchange's deadline.
    case timedOut
    case malformedFrame
    /// Discord answered with an error, such as an unknown application ID.
    case rejected(String)

    public var message: String {
        switch self {
        case .discordNotRunning: "Discord isn't open."
        case .connectionLost: "Lost the connection to Discord."
        case .timedOut: "Discord didn't answer in time."
        case .malformedFrame: "Discord sent something Tempus didn't understand."
        case let .rejected(reason): "Discord said: \(reason)"
        }
    }
}

/// The local connection to the Discord app that rich presence goes through.
public protocol DiscordConnection: Sendable {
    /// Connects and introduces Tempus as the Discord application `clientID`.
    func open(clientID: String) async throws(DiscordIPCError)
    /// Shows `activity` in the user's status, or clears it when nil.
    func setActivity(_ activity: DiscordActivity?) async throws(DiscordIPCError)
    func close() async
}

public enum DiscordOpcode: UInt32, Sendable {
    case handshake = 0
    case frame = 1
    case close = 2
    case ping = 3
    case pong = 4
}

/// One message of Discord's local IPC: a little-endian opcode and payload length, then JSON.
public struct DiscordFrame: Sendable, Equatable {
    static let headerSize = 8
    /// Far more than any real message; a larger length means the stream is out of step.
    static let maxPayload = 64 * 1024

    public let opcode: DiscordOpcode
    public let payload: Data

    public init(opcode: DiscordOpcode, payload: Data) {
        self.opcode = opcode
        self.payload = payload
    }

    public func encoded() -> Data {
        var data = Data(capacity: Self.headerSize + payload.count)
        Self.appendLittleEndian(opcode.rawValue, to: &data)
        Self.appendLittleEndian(UInt32(payload.count), to: &data)
        data.append(payload)
        return data
    }

    /// The first frame in `buffer` and how many bytes it took, or nil until the whole frame is there.
    public static func decode(_ buffer: Data) throws(DiscordIPCError) -> (frame: DiscordFrame, length: Int)? {
        guard buffer.count >= headerSize else { return nil }
        let start = buffer.startIndex
        guard let opcode = DiscordOpcode(rawValue: readLittleEndian(buffer, at: start)) else {
            throw .malformedFrame
        }
        let length = Int(readLittleEndian(buffer, at: start + 4))
        guard length <= maxPayload else { throw .malformedFrame }
        guard buffer.count >= headerSize + length else { return nil }
        let payloadStart = start + headerSize
        let payload = Data(buffer[payloadStart ..< payloadStart + length])
        return (DiscordFrame(opcode: opcode, payload: payload), headerSize + length)
    }

    static func handshake(clientID: String) throws(DiscordIPCError) -> DiscordFrame {
        try DiscordFrame(opcode: .handshake, payload: json(Handshake(clientID: clientID)))
    }

    static func setActivity(_ activity: DiscordActivity?, pid: Int32, nonce: String) throws(DiscordIPCError)
        -> DiscordFrame
    {
        let command = ActivityCommand(args: .init(pid: pid, activity: activity.map(ActivityPayload.init)), nonce: nonce)
        return try DiscordFrame(opcode: .frame, payload: json(command))
    }

    private static func json(_ value: some Encodable) throws(DiscordIPCError) -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw .malformedFrame
        }
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func readLittleEndian(_ data: Data, at index: Data.Index) -> UInt32 {
        (0 ..< 4).reduce(UInt32(0)) { value, offset in
            value | UInt32(data[index + offset]) << (8 * UInt32(offset))
        }
    }
}

// MARK: - Payloads

private struct Handshake: Encodable {
    let version = 1
    let clientID: String

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case clientID = "client_id"
    }
}

private struct ActivityCommand: Encodable {
    struct Arguments: Encodable {
        let pid: Int32
        /// Left out to clear the status.
        let activity: ActivityPayload?
    }

    let cmd = "SET_ACTIVITY"
    let args: Arguments
    let nonce: String
}

private struct ActivityPayload: Encodable {
    struct Timestamps: Encodable {
        let start: Int64?
        let end: Int64?
    }

    /// "Listening to", rather than "Playing".
    static let listening = 2

    let type = Self.listening
    let details: String
    let state: String?
    let timestamps: Timestamps?

    init(_ activity: DiscordActivity) {
        details = activity.details
        state = activity.state
        let start = activity.start.flatMap(Self.milliseconds)
        let end = activity.end.flatMap(Self.milliseconds)
        timestamps = start == nil && end == nil ? nil : Timestamps(start: start, end: end)
    }

    /// Nil rather than a trap for a time that isn't a finite number of milliseconds.
    private static func milliseconds(_ date: Date) -> Int64? {
        Int64(exactly: (date.timeIntervalSince1970 * 1000).rounded())
    }
}

/// What Discord sends back: an event name, and a message when something went wrong.
struct DiscordReply: Decodable {
    struct Details: Decodable {
        let code: Int?
        let message: String?
    }

    let evt: String?
    let nonce: String?
    let data: Details?
    /// Close frames put these at the top level.
    let code: Int?
    let message: String?
}

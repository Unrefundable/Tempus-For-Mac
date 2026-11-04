import Darwin
import Darwin.membership
import Foundation
import os

/// Discord's IPC over its Unix socket (`discord-ipc-0` to `-9` in the account's temporary folder).
///
/// The socket is non-blocking and each exchange (connecting with the handshake, or one status
/// update) has a single deadline, so a hung or misbehaving Discord costs at most
/// `exchangeTimeout`. The waiting happens on the connection's own serial queue, never on Swift's
/// cooperative threads. `@unchecked Sendable` because every mutable property is only touched on
/// `queue`.
public final class DiscordSocketConnection: DiscordConnection, @unchecked Sendable {
    private static let logger = Logger(subsystem: "io.github.unrefundable.TempusMac", category: "Discord")
    public static let exchangeTimeout = DispatchTimeInterval.seconds(5)
    private static let readChunk = 4096
    /// Frames to read past while looking for a reply, so a chatty peer can't keep an exchange going.
    private static let maxFramesPerReply = 16
    /// How much of Discord's own error text is shown in Settings.
    private static let messageLimit = 200

    private let paths: [String]
    private let timeout: DispatchTimeInterval
    private let queue = DispatchQueue(label: "io.github.unrefundable.TempusMac.discord")
    private var descriptor: Int32 = -1
    private var buffer = Data()

    /// - Parameter timeout: how long one exchange may take in all.
    public init(
        paths: [String] = DiscordSocketConnection.candidatePaths(),
        timeout: DispatchTimeInterval = DiscordSocketConnection.exchangeTimeout
    ) {
        self.paths = paths
        self.timeout = timeout
    }

    // MARK: Where the socket is

    /// `discord-ipc-0` to `-9` in the account's temporary folder: the only place the sandbox lets
    /// Tempus connect to. Falls back to the folder the system reports if the account can't be
    /// looked up.
    public static func candidatePaths() -> [String] {
        guard let folder = accountTemporaryFolder() ?? reportedTemporaryFolder() else { return [] }
        let base = folder.hasSuffix("/") ? folder : folder + "/"
        return (0 ..< 10).map { "\(base)discord-ipc-\($0)" }
    }

    /// The account's temporary folder (`/var/folders/xx/…/T/`), worked out the way macOS names it
    /// rather than asked for, so it's the real one even inside the sandbox, where `confstr` and
    /// `TMPDIR` give the app's container.
    static func accountTemporaryFolder() -> String? {
        let uid = getuid()
        var uuid = [UInt8](repeating: 0, count: uuidSize)
        let result = uuid.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return EINVAL }
            return mbr_uid_to_uuid(uid, base)
        }
        guard result == 0 else {
            logger.error("Couldn't look up the account to find Discord: \(String(cString: strerror(result)))")
            return nil
        }
        return temporaryFolder(uuid: uuid, uid: uid)
    }

    private static let uuidSize = 16
    /// The digits macOS spells a user's folders with, five bits each.
    private static let folderAlphabet = Array("0123456789_bcdfghjklmnpqrstvwxyz")

    /// The account's UUID then its user ID, big-endian, in five-bit digits: the first two name
    /// the parent folder and the rest the user's own.
    static func temporaryFolder(uuid: [UInt8], uid: uid_t) -> String {
        let bytes = uuid + withUnsafeBytes(of: uid.bigEndian, Array.init)
        var digits: [Character] = []
        var accumulator = 0
        var bitCount = 0
        for byte in bytes {
            accumulator = (accumulator << 8) | Int(byte)
            bitCount += 8
            while bitCount >= 5 {
                bitCount -= 5
                digits.append(folderAlphabet[(accumulator >> bitCount) & 0x1F])
            }
            accumulator &= (1 << bitCount) - 1
        }
        return "/var/folders/\(String(digits.prefix(2)))/\(String(digits.dropFirst(2)))/T/"
    }

    /// The temporary folder the system reports: the real one outside the sandbox.
    private static func reportedTemporaryFolder() -> String? {
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &bytes, size) > 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Discord's own words, made safe to show: no control characters, and not too long.
    static func sanitized(_ text: String?) -> String? {
        guard let text else { return nil }
        let scalars = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let trimmed = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > messageLimit ? String(trimmed.prefix(messageLimit)) + "…" : trimmed
    }

    // MARK: DiscordConnection

    public func open(clientID: String) async throws(DiscordIPCError) {
        try await onQueue { connection, deadline throws(DiscordIPCError) in
            try connection.openNow(clientID: clientID, deadline: deadline)
        }
    }

    public func setActivity(_ activity: DiscordActivity?) async throws(DiscordIPCError) {
        try await onQueue { connection, deadline throws(DiscordIPCError) in
            try connection.setActivityNow(activity, deadline: deadline)
        }
    }

    public func close() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.closeNow()
                continuation.resume()
            }
        }
    }

    /// Runs `body` on the connection's queue with a fresh deadline.
    private func onQueue(
        _ body: @escaping @Sendable (DiscordSocketConnection, DispatchTime) throws(DiscordIPCError) -> Void
    ) async throws(DiscordIPCError) {
        let failure = await withCheckedContinuation { (continuation: CheckedContinuation<DiscordIPCError?, Never>) in
            queue.async {
                do throws(DiscordIPCError) {
                    try body(self, .now() + self.timeout)
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: error)
                }
            }
        }
        if let failure {
            throw failure
        }
    }

    // MARK: Exchanges, on the queue

    private func openNow(clientID: String, deadline: DispatchTime) throws(DiscordIPCError) {
        closeNow()
        var wasRefused = false
        for path in paths {
            if let connected = Self.connect(to: path, deadline: deadline, wasRefused: &wasRefused) {
                descriptor = connected
                break
            }
        }
        if wasRefused {
            Self.logger.error("The sandbox kept Tempus from Discord's socket")
        }
        guard descriptor >= 0 else { throw .discordNotRunning }
        do throws(DiscordIPCError) {
            try write(DiscordFrame.handshake(clientID: clientID), deadline: deadline)
            let reply = try readReply(deadline: deadline) { $0.evt == "READY" || $0.evt == "ERROR" }
            guard reply.evt == "READY" else {
                throw DiscordIPCError.rejected(Self.sanitized(reply.data?.message) ?? "the handshake failed")
            }
        } catch {
            closeNow()
            throw error
        }
    }

    private func setActivityNow(_ activity: DiscordActivity?, deadline: DispatchTime) throws(DiscordIPCError) {
        guard descriptor >= 0 else { throw .connectionLost }
        let nonce = UUID().uuidString
        let pid = ProcessInfo.processInfo.processIdentifier
        try write(DiscordFrame.setActivity(activity, pid: pid, nonce: nonce), deadline: deadline)
        let reply = try readReply(deadline: deadline) { $0.nonce == nonce }
        if reply.evt == "ERROR" {
            throw .rejected(Self.sanitized(reply.data?.message) ?? "the status was refused")
        }
    }

    private func closeNow() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
        descriptor = -1
        buffer = Data()
    }

    // MARK: Frames, on the queue

    /// The first reply `matches` accepts, answering pings and skipping other events on the way. A
    /// close frame ends the connection.
    private func readReply(
        deadline: DispatchTime,
        matches: (DiscordReply) -> Bool
    ) throws(DiscordIPCError) -> DiscordReply {
        for _ in 0 ..< Self.maxFramesPerReply {
            let frame = try readFrame(deadline: deadline)
            switch frame.opcode {
            case .ping:
                try write(DiscordFrame(opcode: .pong, payload: frame.payload), deadline: deadline)
            case .close:
                let reply = try? JSONDecoder().decode(DiscordReply.self, from: frame.payload)
                closeNow()
                throw .rejected(Self.sanitized(reply?.message) ?? "Discord closed the connection")
            case .frame, .handshake, .pong:
                let reply: DiscordReply
                do {
                    reply = try JSONDecoder().decode(DiscordReply.self, from: frame.payload)
                } catch {
                    throw .malformedFrame
                }
                if matches(reply) {
                    return reply
                }
            }
        }
        throw .malformedFrame
    }

    private func readFrame(deadline: DispatchTime) throws(DiscordIPCError) -> DiscordFrame {
        while true {
            if let (frame, length) = try DiscordFrame.decode(buffer) {
                buffer = Data(buffer.dropFirst(length))
                return frame
            }
            var chunk = [UInt8](repeating: 0, count: Self.readChunk)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                buffer.append(contentsOf: chunk.prefix(count))
            } else {
                try recover(from: count == 0 ? 0 : errno, waitingFor: Int16(POLLIN), until: deadline)
            }
        }
    }

    private func write(_ frame: DiscordFrame, deadline: DispatchTime) throws(DiscordIPCError) {
        let bytes = [UInt8](frame.encoded())
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw in
                Darwin.write(descriptor, raw.baseAddress?.advanced(by: offset), raw.count - offset)
            }
            if written > 0 {
                offset += written
            } else {
                try recover(from: written == 0 ? 0 : errno, waitingFor: Int16(POLLOUT), until: deadline)
            }
        }
    }

    /// After a read or write that moved nothing: returns to retry when it was interrupted or the
    /// socket wasn't ready yet (waiting for it first), and ends the connection otherwise.
    /// `code` is 0 for end of file.
    private func recover(from code: Int32, waitingFor events: Int16, until deadline: DispatchTime)
        throws(DiscordIPCError)
    {
        switch code {
        case EINTR:
            return
        case EAGAIN, EWOULDBLOCK:
            try wait(for: events, until: deadline)
        default:
            closeNow()
            throw .connectionLost
        }
    }

    /// Waits until the socket is ready for `events`, or throws once `deadline` passes.
    private func wait(for events: Int16, until deadline: DispatchTime) throws(DiscordIPCError) {
        while true {
            let timeout = Self.milliseconds(until: deadline)
            guard timeout > 0 else {
                closeNow()
                throw .timedOut
            }
            var request = pollfd(fd: descriptor, events: events, revents: 0)
            let ready = poll(&request, 1, timeout)
            if ready > 0 {
                return
            }
            if ready < 0, errno == EINTR {
                continue
            }
            closeNow()
            throw ready == 0 ? .timedOut : .connectionLost
        }
    }

    private static func milliseconds(until deadline: DispatchTime) -> Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline.uptimeNanoseconds > now else { return 0 }
        return Int32(clamping: (deadline.uptimeNanoseconds - now) / 1_000_000)
    }

    // MARK: Connecting

    /// A connected non-blocking socket without SIGPIPE, or nil when nothing listens at `path`.
    /// Sets `wasRefused` when the sandbox said no.
    private static func connect(to path: String, deadline: DispatchTime, wasRefused: inout Bool) -> Int32? {
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        let code = errno
        if result == 0 || (code == EINPROGRESS && finishesConnecting(descriptor, deadline: deadline)) {
            return descriptor
        }
        // Missing or stale sockets are expected; a refusal from the sandbox is worth knowing about.
        if code == EPERM || code == EACCES {
            wasRefused = true
        }
        Darwin.close(descriptor)
        return nil
    }

    private static func finishesConnecting(_ descriptor: Int32, deadline: DispatchTime) -> Bool {
        var request = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&request, 1, milliseconds(until: deadline)) > 0 else { return false }
        var failure: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &length) == 0 && failure == 0
    }
}

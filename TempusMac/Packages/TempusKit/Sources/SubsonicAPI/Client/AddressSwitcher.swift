import Foundation

/// Chooses between a server's local (home) and public (away) address, as upstream
/// `MainActivity.pingServer` / `probeLocalAddress` do:
/// - On the local address, if it stops answering, fall back to the public address.
/// - On the public address, probe the local address (at most every 15 s after a failure) and
///   move to it as soon as it answers.
/// - Identical addresses never ping-pong (upstream issue #242).
/// Call `refresh()` when the app becomes active or the network changes. Persist `inUse`.
public actor AddressSwitcher {
    public static let localProbeCooldown: TimeInterval = 15

    public let publicAddress: ServerAddress
    public let localAddress: ServerAddress?
    public private(set) var inUse: ServerAddress

    private let isReachable: @Sendable (ServerAddress) async -> Bool
    private let now: @Sendable () -> Date
    private var lastFailedLocalProbe: Date?
    private var inFlight: Task<ServerAddress?, Never>?

    public init(
        publicAddress: ServerAddress,
        localAddress: ServerAddress?,
        inUse: ServerAddress? = nil,
        isReachable: @escaping @Sendable (ServerAddress) async -> Bool,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.publicAddress = publicAddress
        self.localAddress = localAddress
        self.inUse = inUse.flatMap { $0 == localAddress ? $0 : nil } ?? publicAddress
        self.isReachable = isReachable
        self.now = now
    }

    /// The address to use now, or nil when neither answers. A call made while a check is running
    /// shares that check's result, as upstream ignores pings while a probe is outstanding.
    public func refresh() async -> ServerAddress? {
        if let inFlight {
            return await inFlight.value
        }
        let task = Task { await resolve() }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    private func resolve() async -> ServerAddress? {
        if let localAddress, inUse == localAddress {
            return await resolveFromLocal(localAddress)
        }
        return await resolveFromPublic()
    }

    private func resolveFromLocal(_ local: ServerAddress) async -> ServerAddress? {
        if await isReachable(local) {
            return local
        }
        guard publicAddress != local else { return nil }
        lastFailedLocalProbe = now()
        inUse = publicAddress
        return await isReachable(publicAddress) ? publicAddress : nil
    }

    private func resolveFromPublic() async -> ServerAddress? {
        if let localAddress, localAddress != publicAddress, mayProbeLocal {
            if await isReachable(localAddress) {
                inUse = localAddress
                return localAddress
            }
            lastFailedLocalProbe = now()
        }
        return await isReachable(publicAddress) ? publicAddress : nil
    }

    private var mayProbeLocal: Bool {
        guard let lastFailedLocalProbe else { return true }
        return now().timeIntervalSince(lastFailedLocalProbe) > Self.localProbeCooldown
    }
}

import Foundation
import Observation
import Playback

/// Shows the track playing in the user's Discord status while Settings › General › Discord is on.
/// Gets the player's snapshots through the system's Now Playing, connects to the Discord app only
/// when there's something to show, and sends only real changes, since Discord limits how often a
/// status may change.
@MainActor
@Observable
public final class DiscordPresence: NowPlayingPublishing {
    /// Tempus's Discord application, whose name Discord shows ("Listening to Tempus"). Not
    /// secret: every Discord client sends its application's ID in the clear.
    public nonisolated static let applicationID = "1567403160258084894"

    public enum Status: Equatable, Sendable {
        case off
        /// On, with nothing playing to show.
        case waiting
        case connecting
        case connected
        /// Couldn't reach Discord or it refused; the message is safe to show.
        case unavailable(String)
    }

    /// What this connection last told Discord to show.
    private enum Shown {
        case nothing
        case activity(DiscordActivity?)
    }

    public private(set) var status = Status.off

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let makeConnection: @Sendable () -> any DiscordConnection
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let retryDelay: Duration

    @ObservationIgnored private var desired: DiscordActivity?
    @ObservationIgnored private var connection: (any DiscordConnection)?
    @ObservationIgnored private var shown = Shown.nothing
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var needsAnotherSync = false
    @ObservationIgnored private var retry: Task<Void, Never>?

    /// - Parameters:
    ///   - debounce: how long to wait for more changes before sending, so skipping through
    ///     tracks sends one update.
    ///   - retryDelay: how long to wait before trying Discord again after it couldn't be reached.
    public init(
        settings: AppSettings,
        makeConnection: @escaping @Sendable () -> any DiscordConnection = { DiscordSocketConnection() },
        now: @escaping @Sendable () -> Date = { Date() },
        debounce: Duration = .seconds(1),
        retryDelay: Duration = .seconds(15)
    ) {
        self.settings = settings
        self.makeConnection = makeConnection
        self.now = now
        self.debounce = debounce
        self.retryDelay = retryDelay
        observeSetting()
        refresh()
    }

    public func publish(_ snapshot: NowPlayingSnapshot?) {
        let activity = DiscordActivity(snapshot: snapshot, now: now())
        desired = activity
        if case let .activity(current) = shown, Self.same(current, activity) {
            return
        }
        scheduleSync()
    }

    /// Applies the setting and tries Discord again now instead of waiting for the retry.
    public func refresh() {
        retry?.cancel()
        retry = nil
        scheduleSync()
    }

    /// Waits until every pending update has been sent.
    func settled() async {
        while let pump {
            await pump.value
        }
    }

    // MARK: Syncing

    private func scheduleSync() {
        needsAnotherSync = true
        guard pump == nil else { return }
        pump = Task { [weak self] in
            await self?.runPump()
        }
    }

    private func runPump() async {
        while needsAnotherSync {
            needsAnotherSync = false
            if debounce > .zero {
                do {
                    try await Task.sleep(for: debounce)
                } catch {
                    break
                }
            }
            await sync()
        }
        pump = nil
    }

    /// Brings Discord in line with the setting and what's playing.
    private func sync() async {
        guard settings.sharesNowPlayingOnDiscord else {
            await disconnect(clearing: true)
            status = .off
            return
        }
        let wanted = desired
        if connection == nil {
            guard wanted != nil else {
                status = .waiting
                return
            }
            guard retry == nil else { return }
            guard await connect() else { return }
        }
        await show(wanted)
    }

    private func connect() async -> Bool {
        status = .connecting
        let candidate = makeConnection()
        do {
            try await candidate.open(clientID: Self.applicationID)
        } catch {
            status = .unavailable(error.message)
            scheduleRetry()
            return false
        }
        connection = candidate
        shown = .nothing
        status = .connected
        return true
    }

    private func show(_ wanted: DiscordActivity?) async {
        guard let connection else { return }
        switch shown {
        case let .activity(current) where Self.same(current, wanted):
            return
        case .nothing where wanted == nil:
            return
        default:
            break
        }
        do {
            try await connection.setActivity(wanted)
            shown = .activity(wanted)
            status = wanted == nil ? .waiting : .connected
        } catch {
            await disconnect(clearing: false)
            status = .unavailable(error.message)
            scheduleRetry()
        }
    }

    /// Closing the connection clears the status on Discord's side too; `clearing` also says so
    /// first, for when the user turned sharing off.
    private func disconnect(clearing: Bool) async {
        guard let connection else { return }
        self.connection = nil
        if clearing, case .activity(.some) = shown {
            do {
                try await connection.setActivity(nil)
            } catch {
                // Closing below clears it anyway.
            }
        }
        shown = .nothing
        await connection.close()
    }

    private func scheduleRetry() {
        retry?.cancel()
        let delay = retryDelay
        retry = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            self?.retry = nil
            self?.scheduleSync()
        }
    }

    private func observeSetting() {
        withObservationTracking {
            _ = settings.sharesNowPlayingOnDiscord
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeSetting()
                self?.refresh()
            }
        }
    }

    private static func same(_ first: DiscordActivity?, _ second: DiscordActivity?) -> Bool {
        switch (first, second) {
        case (nil, nil): true
        case let (first?, second?): first.isSimilar(to: second)
        default: false
        }
    }
}

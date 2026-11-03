import Foundation
import Observation
import SubsonicAPI

/// Getting an offline session back online without the Reconnect button: a bounded round of
/// retries (`ReconnectPolicy`) when the session opens offline or the network changes, then an
/// in-place switch to the server, held while music plays so it isn't cut off.
public extension AppModel {
    /// What an offline session is doing about getting back online.
    enum ReconnectStatus: Sendable, Equatable {
        /// Not trying: online, signed out, or the last round ran out. Reconnect still works.
        case idle
        /// Trying the server again in the background.
        case retrying
        /// The server answers again; the switch waits for playback to pause so music isn't cut off.
        case waitingForPause
    }
}

extension AppModel {
    /// Starts a fresh round of retries for the offline session, replacing any round in progress,
    /// so there is never more than one.
    func startReconnecting() {
        guard let offline = session, offline.isOffline else { return }
        stopReconnecting()
        let round = reconnectRound
        reconnectStatus = .retrying
        reconnectTask = Task { [weak self] in
            await self?.retry(offline, round: round)
        }
    }

    func stopReconnecting() {
        reconnectRound += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectStatus = .idle
    }

    /// Whether `round` is still the one in progress, for the session it started on.
    private func isCurrent(_ round: Int, for offline: ServerSession) -> Bool {
        round == reconnectRound && session === offline
    }

    /// Tries the server once after each of the policy's waits. Ends when it answers (switching
    /// to it), refuses the account, the waits run out, or a newer round or connect takes over.
    private func retry(_ offline: ServerSession, round: Int) async {
        let profile = offline.profile
        let delays = environment.reconnectPolicy.delays
        for (index, delay) in delays.enumerated() {
            do {
                try await environment.sleep(delay)
            } catch {
                return // cancelled: whoever cancelled has taken over
            }
            guard isCurrent(round, for: offline) else { return }
            let credentials: ServerCredentials
            do {
                credentials = try await accounts.credentials(for: profile)
            } catch {
                Self.logger.error("Stopped reconnecting: couldn't read the server's credentials: \(error)")
                return finishReconnecting(round, for: offline)
            }
            let reached = await reach(credentials)
            guard isCurrent(round, for: offline) else { return }
            switch reached {
            case .offline:
                Self.logger.info("Reconnect attempt \(index + 1) of \(delays.count): no answer")
            case let .refused(error):
                // Leave the offline session as it is: Reconnect shows why, on the server list.
                Self.logger.error("Stopped reconnecting: the server refused the account: \(error)")
                return finishReconnecting(round, for: offline)
            case let .online(client, info):
                return await goOnline(from: offline, client: client, info: info, round: round)
            }
        }
        Self.logger.info("Stopped reconnecting: the server didn't answer")
        finishReconnecting(round, for: offline)
    }

    private func finishReconnecting(_ round: Int, for offline: ServerSession) {
        guard isCurrent(round, for: offline) else { return }
        reconnectTask = nil
        reconnectStatus = .idle
    }

    /// Swaps the offline session for one on the server that answered, without the connecting
    /// screen: the queue carries over paused where it was, as after Reconnect. While music plays
    /// the switch waits, since handing the engine over stops it.
    private func goOnline(from offline: ServerSession, client: SubsonicClient, info: ServerInfo, round: Int) async {
        guard !offline.player.status.isActive else { return waitForPause(offline, round: round) }
        await offline.player.savePosition()
        let saved = await savedQueue(server: offline.profile.id)
        guard isCurrent(round, for: offline) else { return }
        guard !offline.player.status.isActive else { return waitForPause(offline, round: round) }

        // Committed from here: the old session stops before the new one starts, as in `connect`.
        // Paused like there too, so a play pressed while it ends isn't cut off by the handover.
        reconnectTask = nil
        reconnectStatus = .idle
        detachNowPlaying()
        offline.player.pause()
        await offline.end()
        // A connect or sign-out that started meanwhile has ended this session itself.
        guard session === offline else { return }
        Self.logger.info("Reconnected to the server")
        install(profile: offline.profile, client: client, info: info, saved: saved)
    }

    /// Watches the offline player until it stops playing, then starts a fresh round, which tries
    /// the server again before switching. The observation holds the session weakly.
    private func waitForPause(_ offline: ServerSession, round: Int) {
        guard isCurrent(round, for: offline) else { return }
        reconnectTask = nil
        reconnectStatus = .waitingForPause
        let isActive = withObservationTracking {
            offline.player.status.isActive
        } onChange: { [weak self, weak offline] in
            Task { @MainActor in
                guard let self, let offline else { return }
                self.waitForPause(offline, round: round)
            }
        }
        if !isActive {
            startReconnecting()
        }
    }
}

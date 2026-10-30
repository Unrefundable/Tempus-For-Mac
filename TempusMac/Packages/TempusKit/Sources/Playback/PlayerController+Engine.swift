import Foundation
import Persistence
import SubsonicAPI

/// Engine events, loading tracks, the progress tick, the sleep timer and saving.
extension PlayerController {
    func handle(_ event: EngineEvent) {
        switch event {
        case let .started(id): didStart(id)
        case let .finished(id, reason): didFinish(id, reason)
        case let .stateChanged(state): engineStateChanged(state)
        case let .failed(entry, message): didFail(entry: entry, message: message)
        }
    }

    /// Loads the current entry. Without `autoplay` the player just shows it, paused, until play.
    func load(autoplay: Bool, at start: TimeInterval = 0, saving: Bool = true) {
        guard let item = queue.current else {
            stop()
            return
        }
        position = start
        duration = TimeInterval(item.song.duration ?? 0)
        upcomingID = nil
        hasCurrentStarted = false
        countedID = nil
        if item.id == unplayableID {
            unplayableID = nil // its turn: let it fail (or play) on its own
        }
        if saving {
            saveQueue()
        }
        guard autoplay else {
            if isLoaded {
                engine.stop()
            }
            isLoaded = false
            pendingSeek = nil
            status = .paused
            stopTicker()
            publishNowPlaying()
            return
        }
        do {
            let streamItem = try stream(item)
            errorMessage = nil
            pendingSeek = start > 0 ? start : nil
            engine.play(streamItem)
            isLoaded = true
            status = .buffering
            applyGain()
            refreshUpcoming()
            publishNowPlaying()
        } catch {
            Self.logger.error("Couldn't build a stream URL: \(error)")
            didFail(entry: nil, message: String(localized: "This track can't be streamed from the server."))
        }
    }

    private func stream(_ item: QueueItem) throws(SubsonicError) -> EngineItem {
        let quality = settings.stream.quality(
            for: item.song,
            onConstrainedNetwork: environment.isOnConstrainedNetwork()
        )
        return try source.streamItem(for: item, quality: quality)
    }

    /// Keeps the engine's next entry in step with the queue, so tracks join without a gap.
    func refreshUpcoming(force: Bool = false) {
        guard isLoaded else { return }
        let next = queue.nextItem(afterTrackEnded: true).flatMap { $0.id == unplayableID ? nil : $0 }
        guard force || next?.id != upcomingID else { return }
        do {
            try engine.setUpcoming(next.map(stream))
            upcomingID = next?.id
        } catch {
            Self.logger.error("Couldn't build the next stream URL: \(error)")
            upcomingID = nil
            engine.setUpcoming(nil)
        }
    }

    func applyGain() {
        guard let index = queue.currentIndex else { return }
        let previous = index > 0 ? queue.items[index - 1].song : nil
        engine.setGain(decibels: settings.replayGain.gainDB(for: queue.items[index].song, after: previous))
    }

    // MARK: Engine events

    private func didStart(_ id: QueueItem.ID) {
        guard let item = queue.items.first(where: { $0.id == id }) else { return }
        // After the first start, every start is the engine taking its upcoming entry.
        if hasCurrentStarted, id == upcomingID {
            upcomingID = nil
        }
        hasCurrentStarted = true
        countedID = nil
        queue = queue.selecting(id)
        errorMessage = nil
        if let pendingSeek {
            engine.seek(to: pendingSeek)
            position = pendingSeek
            self.pendingSeek = nil
        } else {
            position = 0
        }
        duration = TimeInterval(item.song.duration ?? 0)
        applyGain()
        if ScrobblePolicy.counts(item.song) {
            eventSink.yield(.nowPlaying(item.song))
        }
        refreshUpcoming()
        saveProgress()
        publishNowPlaying()
    }

    private func didFinish(_ id: QueueItem.ID, _ reason: EngineFinish) {
        guard reason == .ended, let item = queue.items.first(where: { $0.id == id }) else { return }
        if ScrobblePolicy.counts(item.song) {
            eventSink.yield(.played(item.song, at: environment.now()))
        }
        countedID = id
        if settings.sleepTimer == .endOfTrack {
            // The fade didn't get its chance (an unknown length, say): stop here anyway.
            cancelFade()
            engine.pause()
            status = .paused
            updateSettings { $0.sleepTimer = .off }
            stopTicker()
        }
        if id == queue.currentID {
            if let next = queue.nextItem(afterTrackEnded: true) {
                if next.id != upcomingID {
                    // The engine had nothing queued (an edit at the last moment, or a track that
                    // failed ahead of time), so it has stopped: start the next track here.
                    queue = queue.selecting(next.id)
                    load(autoplay: status.isActive)
                    return
                }
            } else {
                isLoaded = false
                status = .stopped
                position = 0
                stopTicker()
            }
        }
        saveProgress()
        publishNowPlaying()
    }

    private func engineStateChanged(_ state: EngineState) {
        guard status.isActive else { return }
        switch state {
        case .buffering:
            status = .buffering
        case .playing:
            status = .playing
            startTicker()
        case .idle, .paused, .stopped:
            return // the controller decides these itself
        }
        publishNowPlaying()
    }

    /// Upstream doesn't skip a failed track: it stops, and play retries from the same spot.
    private func didFail(entry: QueueItem.ID?, message: String) {
        if let entry, isLoaded, entry != queue.currentID, entry == upcomingID {
            // The next track failed while downloading ahead. AudioStreaming stops everything, so
            // pick the current one up again and leave the bad one to fail on its own turn.
            Self.logger.error("The next track failed while downloading ahead; resuming the current one")
            unplayableID = entry
            load(autoplay: status.isActive, at: position, saving: false)
            return
        }
        errorMessage = message
        if isLoaded {
            engine.stop()
        }
        isLoaded = false
        status = .paused
        stopTicker()
        saveProgress()
        publishNowPlaying()
    }

    func countSkippedTrack() {
        guard isLoaded, let current = queue.current, current.id != countedID, ScrobblePolicy.counts(current.song),
              ScrobblePolicy.meetsThreshold(duration: duration, position: position)
        else { return }
        countedID = current.id
        eventSink.yield(.played(current.song, at: environment.now()))
    }

    // MARK: Progress and the sleep timer

    /// Reads the engine's position. Runs twice a second while playing.
    func tick() {
        guard isLoaded else { return }
        position = engine.progress
        if engine.duration > 0 {
            duration = engine.duration
        }
        checkSleepTimer()
        if status == .playing, environment.now().timeIntervalSince(lastProgressSave) >= Self.progressSaveInterval {
            saveProgress()
        }
    }

    func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: PlayerController.tickInterval)
                guard let self else { return }
                tick()
            }
        }
    }

    func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func checkSleepTimer() {
        guard fade == nil, status.isActive else { return }
        // In real time: at 2× the last 10 seconds of a track take 5.
        let timeLeft = duration > 0 ? (duration - position) / settings.speed.rate : nil
        guard settings.sleepTimer.shouldStartFade(now: environment.now(), timeLeftInTrack: timeLeft) else { return }
        startFade()
    }

    /// Fades the volume out over 10 seconds, pauses, then restores the volume (upstream's timings).
    private func startFade() {
        let environment = environment
        fade = Task { [weak self] in
            do {
                for step in 1 ... SleepTimer.fadeSteps {
                    try await environment.sleep(SleepTimer.fadeStepInterval)
                    try Task.checkCancellation()
                    self?.engine.volume = SleepTimer.fadeVolume(afterStep: step)
                }
                self?.finishFade()
                try await environment.sleep(PlayerController.volumeRestoreDelay)
            } catch {
                return // cancelled by a pause or a timer change; `cancelFade` restored the volume
            }
            self?.engine.volume = 1
        }
    }

    private func finishFade() {
        fade = nil // done: pausing mustn't cancel it before the volume comes back
        pause()
        updateSettings { $0.sleepTimer = .off }
    }

    /// Stops a fade in progress and restores the volume.
    func cancelFade() {
        guard let fade else { return }
        fade.cancel()
        self.fade = nil
        engine.volume = 1
    }

    // MARK: Saving

    func saveQueue() {
        guard let queueSaver else { return }
        let saved = SavedQueue(
            songs: queue.items.map(\.song),
            currentIndex: queue.currentIndex,
            positionMilliseconds: Int64(position * 1000)
        )
        let server = serverID
        enqueueSave { try await queueSaver.save(saved, server: server) }
    }

    func saveProgress() {
        guard let queueSaver, let index = queue.currentIndex else { return }
        lastProgressSave = environment.now()
        let milliseconds = Int64(position * 1000)
        let server = serverID
        enqueueSave {
            try await queueSaver.updateProgress(currentIndex: index, positionMilliseconds: milliseconds, server: server)
        }
    }

    /// Saves run one after another, so an older state never lands after a newer one.
    private func enqueueSave(_ work: @escaping @Sendable () async throws -> Void) {
        let previous = persistence
        persistence = Task {
            await previous?.value
            do {
                try await work()
            } catch {
                Self.logger.error("Couldn't save the play queue: \(error)")
            }
        }
    }

    /// Waits for pending saves and any fade. For tests.
    func settled() async {
        await fade?.value
        await persistence?.value
    }

    // MARK: Now Playing

    func publishNowPlaying() {
        guard let nowPlaying else { return }
        guard let index = queue.currentIndex else {
            nowPlaying.publish(nil)
            return
        }
        nowPlaying.publish(NowPlayingSnapshot(
            song: queue.items[index].song,
            position: position,
            duration: duration,
            rate: status == .playing ? settings.speed.rate : 0,
            status: status,
            queueIndex: index,
            queueCount: queue.items.count
        ))
    }
}

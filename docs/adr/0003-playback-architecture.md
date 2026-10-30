# ADR 0003: Playback architecture

- **Status:** Accepted
- **Date:** 2026-10-30

## Context

Phase 3 ports upstream's player (`MediaManager`, `BaseMediaService`, `ReplayGainUtil`, `SleepTimerManager`, `equalizer/`) onto AudioStreaming, which ADR 0001 chose. Media3 does much of upstream's work implicitly (queue navigation, gapless playback, audio focus), so each of those needed an explicit decision here.

## Decisions

### 1. Vendor AudioStreaming instead of forking it
AudioStreaming 1.4.5 lives in `TempusMac/Vendor/AudioStreaming`, patched for gapless MP3/AAC, a redirect hook, pitch, and hardening against hostile servers (see its `TEMPUS-PATCHES.md`). A fork would need a public repository. Vendoring keeps the patches reviewable in this repo's history, and they can still be offered upstream.

### 2. A thin engine behind a protocol
`PlayerController` (`@MainActor @Observable`) owns all behaviour: the queue, navigation, scrobble rules, the sleep timer, ReplayGain and saving. It drives a `PlayerEngine` that only plays one entry and keeps the next one queued. `StreamingEngine` implements it on AudioStreaming, and the controller's tests use a fake. Real playback is covered by tests that play generated WAV files through `StreamingEngine`, and by a silent live test against the user's server (`scripts/live-test.sh`).

### 3. Queue semantics follow Media3, as upstream sees them
- Repeat one replays a track only when it ends by itself; skip moves on.
- Previous restarts a track after 3 seconds.
- Shuffle reorders with the current track first, and turning it off restores the order tracks were added in.
- Skipping while paused stays paused.
- A failed track stops with a message instead of skipping, and play retries from the same spot.
- The current entry can't be removed.
- A song can be queued twice, so queue entries have their own ids. AudioStreaming identifies entries by URL, so each stream URL gets a unique `#entry=` fragment, which is never sent to the server.

### 4. ReplayGain from the server, through the EQ's global gain
- Gains come from OpenSubsonic `replayGain` only. Upstream also reads tags from the file, which a streaming decoder can't do before playback. Navidrome and other OpenSubsonic servers send the values.
- The formula, fallbacks, auto mode and clipping cap are upstream's.
- The gain is applied as `AVAudioUnitEQ.globalGain`, because the player's volume can't go above 1.0.
- **Limitation:** the gain changes when AudioStreaming reports the next track started, on the main queue. That is a few milliseconds after the audio itself switches. Upstream applies it sample-accurately. If this is ever audible, the fix is a per-entry gain inside AudioStreaming's render callback.

### 5. Formats the player can't decode are transcoded
Opus, Vorbis (which AudioStreaming can't seek in), WMA, APE and WavPack are requested from the server as MP3 at 320 kbps, or in the user's chosen transcode format if they set one. Opus isn't offered as a transcode target.

### 6. Mobile-data settings become constrained-network settings
Upstream has separate Wi-Fi and mobile quality settings. On the Mac, the "mobile" pair applies on a personal hotspot or in Low Data Mode (`NWPath.isExpensive || isConstrained`).

### 7. Equalizer
- One `AVAudioUnitEQ` with 20 bands carries everything: a 10-band graphic EQ (32 Hz to 16 kHz, ±12 dB) or an AutoEQ parametric profile (up to 20 filters).
- Upstream's built-in EQ is whatever Android offers on the device, so the Mac defines its own bands.
- AutoEQ files are parsed with upstream's validation rules.
- Peaking filters convert Q to bandwidth exactly. Shelves use `AVAudioUnitEQ`'s fixed-slope shelves, close to AutoEQ's usual Q of 0.7.

### 8. System integration
- `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` provide Now Playing, media keys and AirPods controls.
- Playback pauses when the output in use disappears (headphones unplugged, Bluetooth disconnecting), as Music does. Choosing another output by hand doesn't pause it.
- AirPlay works through the system output: AudioStreaming renders to the default output unit.

## Consequences

- Scrobbling, history and Continue Listening (Phase 6) consume `PlayerController.events` rather than reaching into the player.
- The patches must be carried forward when AudioStreaming is updated. `GaplessTrimTests` and the spike (`TempusMac/Spike/AudioSpike`, now pointed at the vendored copy) check the gapless patch.

# ADR 0001: Foundation decisions

- **Status:** Accepted. Decision 3 is accepted with one follow-up patch (see Spike result).
- **Date:** 2026-10-29

## Context

Tempus for macOS ports an Android Subsonic client (about 450 Java/Kotlin files) to Swift and SwiftUI. The decisions below are hard to change later, so they are made once here. Each one prefers proven libraries over custom code to keep the work small.

## Decisions

### 1. Minimum macOS 15, Liquid Glass on macOS 26+
Deploy to macOS 15 as CLAUDE.md specifies. Standard controls pick up Liquid Glass automatically when built with the macOS 26+ SDK. Custom glass effects go behind `if #available(macOS 26, *)`.

### 2. GRDB for persistence
GRDB maps directly onto the Room schema (`reference/tempus/app/schemas/.../24.json`). It gives plain SQL and migrations, and it stays fast on libraries with tens of thousands of tracks. SwiftData was rejected because it is slower on large datasets and harder to control from actors.

### 3. AudioStreaming for playback
[AudioStreaming](https://github.com/dimitris-c/AudioStreaming) (MIT) is built on AVAudioEngine. It streams over HTTP, queues tracks gaplessly, and accepts custom `AVAudioNode`s. Amperfy, a shipping GPL Subsonic client, uses it with an `AVAudioUnitEQ` for the equalizer, a mixer node for ReplayGain, and the player's `rate` for speed. Formats it can't decode (Opus, and Vorbis where seeking matters) are requested from the server transcoded with the Subsonic `format` parameter. A custom engine was rejected, and so was SFBAudioEngine, which plays local files only.

### 4. Nuke for artwork
Memory and disk caching, downsampling, prefetching and SwiftUI image views. This replaces the custom image cache actor in CLAUDE.md's mapping table.

### 5. Developer ID distribution with Sparkle
Upstream is GPL-3.0, and the Mac App Store's terms are widely considered incompatible with it. Ship a notarized DMG and update it with Sparkle.

### 6. App Transport Security
Home Subsonic servers often use plain `http` on a LAN address. Allow `NSAllowsLocalNetworking`, and decide in Phase 1 whether user-entered public `http` servers need a per-domain exception or a warning.

### 7. Workflow
Logic lives in the `TempusKit` Swift package so it builds and tests with `swift build` and `swift test`. The Xcode project uses buildable folders, which keeps it free of per-file entries. Reviews run once per phase instead of after every change.

## Consequences

- Dependencies to track: GRDB, AudioStreaming, Nuke, Sparkle.
- Gapless playback and codec coverage depend on AudioStreaming. If the spike fails, revisit this ADR before Phase 3.

## Spike result (decision 3)

**Method.** I tested AudioStreaming 1.4.5 with the harness in `TempusMac/Spike/AudioSpike`. It plays a 6 s, 440 Hz sine split exactly in half: a.<ext> is queued, then b.<ext>, served over HTTP from 127.0.0.1 by a server that supports Range requests. A frame-filter tap on the main mixer records the output. If playback is gapless, there is no silence at the join, and the "click ratio" stays at 1.0. The click ratio compares the largest break from the sine's recurrence at the join with the largest break anywhere else. To reproduce it, run `scripts/make-media.sh`, then `scripts/range_server.py`, then `swift run AudioSpike`.

| Format | Gapless join | Seek over HTTP | Notes |
|---|---|---|---|
| FLAC | **Yes** (0 ms, ratio 1.00) | Yes | |
| ALAC (.m4a) | **Yes** (0 ms, ratio 1.00) | Yes | |
| MP3 (LAME, 256k) | No: 18 ms gap, click 12.9 | Yes | |
| AAC (ffmpeg) | No: 42 ms gap, click 9.3 | Yes | |
| AAC (Apple afconvert, iTunes gapless info) | No: 65 ms gap | Yes | |
| Ogg Vorbis | Not measured | **No** (library limitation) | A 565 KB file plays. A 14 KB file stops silently, which doesn't happen with real tracks |
| Opus (Ogg) | — | — | **Not supported.** Stops silently with no audio |

| Capability | Result |
|---|---|
| Playback rate (`rate = 2.0`, 3 s track) | 1.54 s (ideal 1.5) |
| Custom `AVAudioUnitEQ` node, `globalGain = +6 dB` | RMS ×2.00 (ideal 2.00) |
| `volume` | Capped at 1.0, so it can't apply positive ReplayGain |
| Custom request headers and an mTLS `clientCertificateProvider` | Supported in the API (not tested in the spike) |

**Why MP3 and AAC aren't gapless.** AudioStreaming reads `kAudioFileStreamProperty_PacketTableInfo` (encoder priming and remainder frames). It uses it only to refine the duration (`AudioFileStreamProcessor.processPacketTableInfo`) and never trims those frames from the decoded output.

**Decision.** Adopt AudioStreaming, with these follow-ups for Phase 3:
1. **Gapless MP3/AAC:** patch AudioStreaming to drop `mPrimingFrames` at the start and `mRemainderFrames` at the end of each entry. Offer it upstream as a PR, and until then use a pinned fork. Re-run this spike to confirm 0 ms for MP3 and AAC. Until then, only lossless formats are gapless.
2. **Opus:** request it from the server transcoded with `format` (for example `aac` or `mp3`), the same way upstream handles transcoding. Decide per track from `suffix` and `contentType` before queueing.
3. **ReplayGain and preamp:** use an `AVAudioUnitEQ`'s `globalGain` (−96 to +24 dB) on the EQ node that is always attached, not `volume`. Apply clipping prevention by capping the gain at −20·log10(peak).
4. **Vorbis seeking:** it isn't supported, so for Vorbis tracks disable the seek bar, or transcode them like Opus.

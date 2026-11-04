# Tempus patches to AudioStreaming

This is [AudioStreaming](https://github.com/dimitris-c/AudioStreaming) 1.4.5 (MIT, see `LICENSE`), vendored so Tempus can patch it. The demo app (`AudioPlayer/`) is left out. Everything else matches the 1.4.5 tag except for the changes below, each marked `Tempus patch` in the source.

To see the patch, diff this folder against a 1.4.5 checkout.

## 1. Gapless MP3 and AAC

AudioStreaming read the packet table (`kAudioFileStreamProperty_PacketTableInfo`) only to refine the duration. Encoder priming at the start of each track and padding at the end were played, which left a 18–65 ms gap between tracks.

- `Streaming/Audio Entry/Models/GaplessTrim.swift` (new): given each decoded chunk, works out how many frames are priming or padding. It scales source frames to the output sample rate and restarts its count after a seek. Tested in `AudioStreamingTests/Streaming/GaplessTrimTests.swift`.
- `AudioEntry.gaplessTrim`: the per-track state, guarded by the entry's lock.
- `AudioFileStreamProcessor`:
  - `processPacketTableInfo` stores the priming and valid frame counts.
  - `processSeek` restarts the count at the seek point. When the seek position is only estimated (a VBR MP3 without a seek table), trimming stops for that entry instead, so the end of the track is never cut.
  - `propertyPacketsProc` passes each chunk the converter writes through `trimDecodedChunk`, which moves the kept frames to the start of the chunk. When a chunk is trimmed, the loop recomputes the free space instead of writing the wrap-around part, which would leave a hole in the ring buffer.

**Measured** with `TempusMac/Spike/AudioSpike` (a 6 s sine split in half, played as two queued tracks):

| Format | Gap before | Gap after | Click ratio after (1.00 is perfect) | Apple's own decoder, same files |
|---|---|---|---|---|
| FLAC, ALAC | 0 ms | 0 ms | 1.00 | — |
| MP3 (LAME) | 18 ms | 0 ms | 1.60 | 4.86 |
| AAC (ffmpeg) | 42 ms | 0 ms | 1.21 | 5.50 |
| AAC (Apple afconvert) | 65 ms | 0 ms | 9.36 | 29.74 |

The last column decodes both halves with `afconvert` (which honours the same gapless metadata) and joins them. Any click left over comes from the lossy encoder at the edge of each file, not from the trim: shifting the trim by even one frame in either direction makes every join 10–20 times worse.

## 2. A redirect hook

URLSession keeps a request's headers when it follows a redirect. Tempus sends custom headers (Cloudflare Access tokens and the like) that must never reach another origin, so `SubsonicClient` checks every redirect hop, and the player now can too.

- `RedirectHandler`, a new public typealias next to `ClientCertificateProvider`.
- `AudioPlayer.init(configuration:clientCertificateProvider:redirectHandler:)` passes it through `NetworkingClient` to `NetworkSessionDelegate`, which implements `urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)`. With no handler, redirects are followed as before.

## 3. Pitch

`AudioPlayer.pitch` (cents, −2400 to 2400) sets the time-pitch unit's pitch, which was fixed at 0. Upstream Tempus can raise the pitch with the speed or set it by hand. The unit is bypassed only when both the rate and the pitch are neutral.

## 4. Hardening against a hostile server

Found in the Phase 3 security review.

- **M4A files with the moov atom at the end** (`Mp4Restructure`, `RemoteMp4Restructure`). Every size and offset in these comes from the server.
  - A moov atom must be 8 bytes to 64 MB, and no bigger than what was received. It used to allocate whatever size the file claimed.
  - Chunk offsets that would overflow now reject the file. Before, they trapped (`UInt32(_:)` and `Int` addition) and crashed the app.
  - The moov fetch is streamed and stops at 64 MB. It used to buffer the whole response, so an endless body exhausted memory. The probe for the atoms has the same cap.
  - The probing requests now carry the stream's headers. Without them, M4A files behind a header-gated proxy (Cloudflare Access) failed. They go through the same redirect hook, so headers still never leave the server.
- **The URL session** (`NetworkingClient.networkingConfiguration`): no shared credential storage, so client certificates stay out of the process-wide store, and TLS 1.2 at least.

## 5. Accurate seeks in FLAC and VBR MP3

AudioStreaming turned a seek time into a byte offset as if the bitrate were constant, unless Core Audio could name the exact packet (it can for WAV, AAC and CBR MP3, but not for FLAC or VBR MP3). Real music isn't constant: in a FLAC with a quiet intro, a seek to 0:05 played from 0:19. The reported position still said 0:05, so synced lyrics showed one line and played another. Clicking a lyric started the song past that line.

- `Streaming/Audio Entry/Models/AccurateSeek.swift` (new):
  - `FlacFrameHeader` finds the next frame header (CRC-8 checked) after a jump and reads the frame's position from it.
  - `FlacSeekSearch` jumps again, interpolating with a bisection fallback, until it lands within 2 s before the target. Below 256 KB of uncertainty it plays on from the last frame known to be before the target.
  - `XingSeekTable` reads the table of contents in a VBR MP3's Xing or LAME header.
- `AudioFileStreamProcessor`:
  - `processSeek` hands FLAC to the search and uses the Xing table for MP3 when the file has one. Other formats seek as before.
  - `parseFileStreamBytes` holds back a FLAC seek's bytes until a frame header settles where it landed, and keeps the start of an MP3 until its first frame has been checked for a Xing header.
- `GaplessTrim.restart(atSourceFrame:keepingFrom:)` drops the samples between the frame a FLAC seek lands on and the target, so playback starts on the exact sample.

Tested in `AudioStreamingTests/Streaming/AccurateSeekTests.swift` and `GaplessTrimTests.swift`, and against the real engine in Tempus's `StreamingEngineTests` (a FLAC that is silent for 6 s, then a rising tone; the pitch heard after a seek gives the position actually played).

**Measured** with rising-tone files, played locally and over HTTP with range requests, after seeks to 5, 20, 12 and 25 s. The figure is the gap between the position played and the position reported:

| Format | Before | After |
|---|---|---|
| WAV, AAC, CBR MP3 | under 0.1 s | under 0.1 s |
| FLAC, constant density | up to 0.7 s | under 0.1 s |
| FLAC, quiet then dense | 2.5–14 s | under 0.1 s |
| VBR MP3, quiet then dense | 2.5–7 s | under 0.2 s, never late |

**Upstream:** all five are worth offering as pull requests. Until they're merged, Tempus uses this copy.

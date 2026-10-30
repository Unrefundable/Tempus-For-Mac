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

**Upstream:** all four are worth offering as pull requests. Until they're merged, Tempus uses this copy.

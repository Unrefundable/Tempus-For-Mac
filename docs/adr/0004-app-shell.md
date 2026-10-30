# ADR 0004: App shell, accounts and artwork

- **Status:** Accepted
- **Date:** 2026-10-30

## Context

Phase 4 turns the Phase 1–3 packages into an app: a login and server list, the main window, the player bar, Now Playing with lyrics and the queue, and cover art. Upstream's login (`LoginServerFragment`, `LoginFragment`), player (`PlayerBottomSheetFragment`, `PlayerControllerFragment`, `ui/queue/`, `PlayerLyricsFragment`) and Glide setup (`CustomGlideRequest`) were traced to decide what to keep.

## Decisions

### 1. Two new package targets; the app target links only `TempusUI`
- `AppCore` holds the logic and is tested with Swift Testing:
  - form validation and connection-error messages;
  - accounts (database plus Keychain) and client-certificate import;
  - the artwork pipeline and lyrics;
  - launch maintenance;
  - the `@MainActor @Observable` `AppModel`.
- `TempusUI` holds the SwiftUI views, with previews built on in-memory data (`PreviewSupport`).
- The Xcode target is two small types: `TempusApp` and its `AppDelegate`. It links `TempusUI` only, and `TempusAppController` hands it the root view, the commands and the termination hook.

### 2. One engine, one session per server
- `AppModel` owns one `StreamingEngine` for the app's life.
- Signing in builds a `ServerSession`: the client for the address that answered, plus a `PlayerController`, artwork, lyrics and the cache-first library.
- Switching servers works in this order:
  1. Pause the old player.
  2. Save its position (`savePosition()`, which saves now rather than waiting up to 15 s).
  3. Hand the engine over with `setPolicy`, which stops it.
  4. Build the new player and restore that server's saved queue, paused.
- Phase 6 scrobbling is not wired yet. `PlayerController.events` buffers its newest 100 plays.

### 3. Connecting follows upstream, but an unreachable server opens offline
- `AddressSwitcher` picks the local or public address; the address in use is kept per server in UserDefaults.
- A server that answers with an error refuses the sign-in, shown on the server list as upstream's toast does. This includes wrong credentials and a proxy's 401 or 403.
- A server that doesn't answer still opens, with an "Offline mode" banner, so cached data shows. This departs from upstream, which stays on the login screen. PLAN.md's cache-first principle asks for it.
- Credentials only move to the local address after a real Subsonic answer from it: `ping` succeeds, or a Subsonic error comes back. Any device can answer a 401 on someone else's LAN IP. The public address still counts a proxy's 401 or 403 as reachable, so the user sees why.
- A remembered address is used only while it is still the profile's local address, and saving a server forgets it. An offline session therefore never sends credentials to an address the profile has dropped.

### 4. The editor tests before saving
- Upstream's Save doesn't ping; only Test does, and only for an already-saved server.
- Here, Save pings the form as typed (the public address, then the local one). If neither answers, it offers **Save Anyway**, so a server that is down right now can still be added.
- Fields, switches, validation order and messages are upstream's: "Mandatory field", "URL not valid", "Invalid header on line N. Use Name: Value".
- Server ids are UUIDs. Upstream's count + 1 can collide after a deletion.
- Saving an address that sends credentials over plain `http` needs an explicit confirmation. That covers a public or local `http` address, and the stronger warning when Plaintext password is also on.
- Deleting removes the Keychain item first. If that fails the server is kept, so the delete can be retried.
- Updating a server whose profile can't be written puts the previous secrets back.

### 5. Client certificates live in the Keychain as the `.p12` file
- `ServerSecrets` gains optional `clientCertificate` and `clientCertificatePassphrase`. Being optional, Phase 2 items still decode.
- The identity is re-created at each session start with `SecPKCS12Import` and `kSecImportToMemoryOnly`, so it is never copied into the login keychain as a separate item.
- Picking a file needs `com.apple.security.files.user-selected.read-only`. Files over 1 MB are refused.
- Imports and Keychain reads run off the main actor (`@concurrent`). PKCS#12 key derivation is slow by design, and the Keychain can block on a permission prompt.

### 6. Artwork through Nuke, keyed by server, cover and size
- Each session gets an `ImagePipeline`. All sessions share one memory cache and a 300 MB disk cache in Caches.
- Requests set `imageID = "server/cover/size"`, because the URL carries the token and salt.
- The `DataLoader` uses an ephemeral session with no URL cache or cookies. Its delegate applies `MediaRequestPolicy`: headers only on the server's origin, stripped from redirects that leave it, and the client certificate only for the server's own challenge.
- Sizes follow upstream:

  | Use | Size |
  |---|---|
  | Player bar and queue | 160 |
  | System Now Playing | 512 |
  | Now Playing view | original (upstream's default "High") |

  The size setting is Phase 9.
- Responses over 20 MB are refused.
- Errors are logged without the request, since Nuke's description contains the credentialed URL.
- A deleted server's covers stay on disk until the LRU removes them. Covers are not secret.

### 7. App Transport Security: local networking only
- ADR 0001 decision 6 is settled this way: `Config/Info.plist` adds only `NSAllowsLocalNetworking`, merged with the generated Info.plist.
- Plain `http` works for LAN names, `.local` and IP addresses. A public `http` address fails, and the message tells the user to use https.
- The editor warns about any `http` address, as upstream documents the risk of a rogue device taking over a local IP.
- `NSLocalNetworkUsageDescription` is set, because macOS 15 asks before an app talks to the LAN. A public name that resolves to a LAN address counts too.

### 8. The lyrics and queue panel is a fixed-width column, not `.inspector`
- SwiftUI's `.inspector` didn't widen a 900 pt window. It pushed the columns past both edges, and once raised an AppKit layout exception.
- A 320 pt trailing column inside the detail, with the player bar along the bottom of the content, always fits the 900 pt minimum width.
- Space toggles play and pause through `onKeyPress`, so it never fires while a text field has focus. Next and Previous are ⌘→ and ⌘←. The full command set is Phase 9.

### 9. Sessions never overlap
- `connect` bumps a generation counter.
- `endSession` clears the session before it awaits the position save, and resets the engine's policy only if no newer session has taken the engine since.
- `startSession` loads the saved queue before the generation check and does not await after it.
- `launch()` runs once, so reopening the window doesn't interrupt playback.
- The Now Playing artwork observation holds the session weakly, so an ended session is released.
- Quitting waits at most 2 s for the save.

### 10. Housekeeping at launch
- `ResponseCache` drops entries older than `CachedLibrary.maximumCacheAge` (30 days).
- `HistoryStore` drops plays older than 366 days, the longest Home section's look-back.

## Consequences

- AppCore is unit-tested against an in-memory database, an in-memory Keychain, a stubbed ping and a fake engine. Views are checked in previews and with the debug-only `-TempusDemo` / `-TempusDemoSignedOut` launch arguments, which run on in-memory data and never touch the real database or Keychain.
- Debug builds are signed ad hoc, so every rebuild has a new signature. The file-based keychain then asks again (or refuses) before handing over a server's secrets. A stable signing identity avoids this.
- Changing address in the middle of a session (local ↔ public when the network changes) is not done yet. The address is chosen at sign-in.

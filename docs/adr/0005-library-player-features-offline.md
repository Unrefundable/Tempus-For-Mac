# ADR 0005: Library, player features, playlists, radio, offline and Mac extras

- **Status:** Accepted
- **Date:** 2026-11-02

## Context

Phases 5–9 turn the Phase 4 shell into the whole app: Home and the library, detail pages and search (5); stars, ratings, scrobbling, Instant Mix, play-queue sync and Continue Listening (6); playlist editing, podcasts, radio and shares (7); downloads (8); and Settings, menus, the menu bar player, the Dock menu and App Intents (9). Upstream's behaviour comes from `USAGE.md`. The app was then driven end to end against a local mock server (`scripts/mock-subsonic.py`), and the defects that turned up are fixed below.

## Decisions

### 1. Services hang off `ServerSession`, and the views stay thin
- AppCore gains `AppSettings` (UserDefaults, nothing secret), `StarService`, `Scrobbler`, `ListeningSync`, `PlaylistService`, `RadioService`, `RadioBrowser`, `ServerFeatures`, `PlaybackSources` and `DownloadManager`.
- `ServerSession` is `@Observable` and is put in the SwiftUI environment.
  - `start()` runs scrobbling and the listening sync, and, when the server answered: sends stars queued offline, probes features and syncs downloads.
  - `end()` stops them and waits for the last saves.
- Each is covered by Swift Testing against a recording transport and an in-memory database.

### 2. Cache-first everywhere through one loader
- `SnapshotView` and Home's `CachedRow` iterate `CachedLibrary.snapshots`. The saved answer draws at once; when the server can't be reached it stays on screen with a quiet notice.
- A `.task` on a view that is empty never starts. Home rows used to hang their loading off an empty `Group`, so Home was blank; rows now always have a one-point frame to carry the task.

### 3. Navigation is drawn by hand, not with `NavigationStack`
- Inside `NavigationSplitView`, a destination pushed on a nested stack replaced the whole detail column, taking the player bar and the lyrics/queue panel with it.
- `Navigator` keeps the sidebar selection and a path of `Route`s. The detail shows the top route, with a Back button and ⌘[.
- The same object serves the Go menu (⌘0–⌘9) and ⌘F, and it is reset when the server changes.

### 4. Upstream's rules, as written in USAGE.md
- **Scrobbling:** "now playing" when a track starts, a submission when it counts (`ScrobblePolicy`). Plays go into local history whether or not scrobbling is on. A failed scrobble isn't resent.
- **Continue Listening:**
  - Podcasts, audiobooks and music over 10 minutes keep their spot as server bookmarks.
  - The spot is saved on pause, Stop, track change, every 15 s and on quit.
  - A track left within 10 s of its end drops its bookmark.
- **Play-queue sync** (off by default): saved on pause, track change, every 30 s and on quit. Load Queue is in the queue menu.
- **Instant Mix:** the track again, then `getSimilarSongs`, inserted after the current track.
- **Stars:** shown at once, queued in `pending_star` when offline, undone with a message when the server refuses.
- **Playlist edits:**
  - Write the list exactly as shown: remove every index the server has now (re-fetched just before saving), then add the edited list, in one `updatePlaylist`.
  - An empty playlist is refused, and so is editing from the offline cache.
  - Faves are local (`pinned_playlist`).
- **Podcasts and Shares** hide only on HTTP 501. Being offline doesn't hide them.
- **Multiple libraries:** the picker shows only with more than one music folder. It reaches browsing and search, never stars, playlists or downloads.

### 5. Long requests go as a form POST
- Saving a long playlist or play queue put hundreds of ids in the query string. nginx's default limit is 8 KB.
- `SubsonicClient` sends any request whose URL exceeds 4,000 characters as `application/x-www-form-urlencoded` POST. Subsonic servers accept that, and OpenSubsonic advertises it as `formPost`.

### 6. Downloads
- **Storage:**
  - Files go in `Application Support/Tempus/Downloads/<server>/<song>.<suffix>`, excluded from backups.
  - Ids and suffixes from the server only become file names when they are plain; otherwise they are hashed.
  - Schema v2 adds `download` and `synced_playlist`. Their rows go with the server, and so do the files.
- **Fetching:**
  - Two files at a time, through URLSession with the server's header, redirect and client-certificate rules.
  - A JSON or XML body instead of audio is reported as the Subsonic error it carries.
  - Nothing starts before the existing downloads are loaded, or after the session ends.
  - "Only on unconstrained networks" holds the queue on a hotspot or in Low Data Mode, and resumes when the network changes.
- **Playing:** `SessionStreamSource` plays a downloaded file from disk, radio from its own address (without the server's headers), and everything else from the server.
- **Keep Synced** fetches missing tracks when the playlist is opened and at sign-in. Starred tracks can be kept downloaded the same way.

### 7. Radio
- **Local stations** are kept for every server, as upstream does, and marked LOCAL.
- **radio-browser.info:** up to 30 stations, most voted first, with a 2 MB response cap. The lookup also fills the station's cover address into the form.
- **Playing:** a station is queued as a `Song` of type `radio` whose `path` carries the stream address. It is never scrobbled, bookmarked or synced.
- **Limitation:** App Transport Security refuses public `http` streams, and many directory entries are `http`. The app says so when such a station is played. Allowing arbitrary loads for every host is not worth weakening ATS for the whole app.

### 8. A stream that never starts gives up
- AudioStreaming retries a dead stream forever.
- `PlayerController` now stops an entry that hasn't started within 20 s and shows "The stream didn't start…".

### 9. Mac extras
- **Settings window:** General, Home (order and visibility), Playback (quality, ReplayGain, pitch), Equalizer (10-band and AutoEQ import) and Downloads.
- **Menus:** Controls (play/pause, Stop ⌘., Next and Previous ⌘→ ⌘←, skip ±10 s ⌥⌘→ ⌥⌘←, Shuffle ⌥⌘S, Repeat ⌥⌘R, Star ⌘L) and Go (⌘0–⌘9, Back ⌘[).
- **Elsewhere:** a menu bar mini player, a Dock menu, and App Intents for Shortcuts.
- **Drag and drop:** songs drag onto the queue and onto playlists, as `SongTransfer` (an exported `io.github.unrefundable.TempusMac.songs` type).
- **Space** stays an `onKeyPress` on the main window. A Space menu shortcut would swallow spaces typed in the search field.

### 10. Debug builds are signed with the developer's certificate
- Ad hoc signatures change on every build, so macOS asked again for the server's Keychain item each time.
- Debug builds can be signed with an "Apple Development" certificate through the git-ignored `TempusMac/Config/Signing.local.xcconfig`, which gives a stable designated requirement. Release stays ad hoc until Developer ID signing exists (Phase 10).
- Builds from the command line pass `-disableAutomaticPackageResolution -skipPackageUpdates`, so they never contact GitHub. Package resolution through git's credential helper was what asked for a github.com Keychain item.

## Consequences

- AppCore is unit-tested end to end with stub transports. The UI was checked by hand against the mock server: browsing, playback, star and rating, Instant Mix, lyrics, playlists (edit, create, add), search, podcasts, radio (add, lookup, error path), downloads (offline playback), Settings, the menus and folder playback.
- **Not checked by hand,** because the automation can't open SwiftUI menus or context menus in the background:
  - context menus and pop-up pickers (library, sort, stream quality);
  - the server menu (switch, sign out) and the share sheet;
  - the menu bar extra and the Dock menu;
  - drag and drop.

  Their actions call the same tested services as the buttons that were checked.

# ADR 0007: Themes and Discord status

- **Status:** Accepted
- **Date:** 2026-11-03

## Context

People asked for two things upstream Tempus doesn't have on the Mac: a way to change the app's colors (presets such as Dark, Light and OLED, plus any color by hex code), and a way to show the track playing in their Discord status.

## Decisions

### 1. A theme is a preset plus the user's own colors
- `AppTheme` (AppCore) holds a `ThemePreset`, light/dark/system, and a color per `ThemeColorRole` that the user set. A role's color is the user's, else the preset's, else the system's.
- It is stored as JSON under `settings.theme` in UserDefaults. Decoding is lenient: an unknown preset, role or bad hex code is skipped, so one bad value can't lose the whole theme.
- Choosing a preset replaces the user's colors, so a preset always looks as its card shows.
- Every preset has a light and a dark set of colors (`ThemePreset.colors(for:)`), and views ask for the set matching the appearance showing (`colorScheme`). A preset switched to the other appearance used to keep its colors, so OLED in light drew black text on black and Midnight drew pale text on the system's light surfaces. A test checks text contrast for every preset in both. The user's own colors apply to both sets.
- An `icons` role colors Tempus's icons (`TempusIconImage`, through the `tempusIconColor` environment value) and the few SF Symbols beside them. Icons whose color means something keep it (`tempusIconKeepsForeground`): errors, toggles that are off, drag handles, empty states. Disabled controls aren't tinted, so they still look disabled. Unset, icons look as before.

### 2. Unset roles keep the system's adaptive styles
- Views draw with `ThemeStyle`, a `ShapeStyle` that resolves the theme from the environment. Unset, it resolves to `.primary`, `.secondary`, `.tertiary`, the accent color, `.bar`, `.red` or `.green`. The default look is unchanged, including vibrancy and selection contrast.
- Backgrounds (`themedBackground`) are only drawn when set. Lists and tables then hide their own background so the color shows through.
- When the background is set, the window toolbar is painted in it too (`themedToolbar`). Otherwise AppKit draws its own grey toolbar on any screen without a scroll view under it (empty states, a header above a table, Now Playing), so the bar changed color from screen to screen.
- Light or dark is set on `NSApp.appearance`, so menus, Settings and the menu bar player follow it.
- Selection highlights in the sidebar and tables stay with the system accent; SwiftUI doesn't expose them.

### 3. Discord through its local IPC socket, off by default
- Discord's desktop app listens on `discord-ipc-0` to `-9` in the user's temporary folder. Tempus speaks its framing (little-endian opcode and length, then JSON): a handshake with a Discord application ID, then `SET_ACTIVITY` with the type "Listening", the title, the artist and start/end times.
- Nothing from the server goes to Discord: no server address, credentials or cover-art URL (those carry auth tokens).
- The socket is non-blocking and runs on its own serial queue, never Swift's cooperative threads. Each exchange (handshake, or one status update) has a five-second deadline, replies are matched to their request by nonce, and Discord's error text is cleaned and shortened before Settings shows it.
- `DiscordPresence` gets the player's snapshots by mirroring the system's Now Playing. It connects only when something plays, sends only real changes (Discord limits status updates), coalesces bursts by a second, and retries every 15 seconds while Discord is closed.
- The setting is off by default, because it tells everyone who can see the user's Discord profile what they're playing.
- Discord shows the name of the application whose ID Tempus sends. Tempus always sends its own (`DiscordPresence.applicationID`), so the status reads "Listening to Tempus"; there's no setting to change it. The ID isn't secret: every Discord client sends its application's ID in the clear.

### 4. A narrow sandbox exception for the socket
- Inside the sandbox, `confstr(_CS_DARWIN_USER_TEMP_DIR)` and `TMPDIR` give the app's container. Tempus works out the real folder the way macOS names it: the account's UUID (`mbr_uid_to_uuid`) and user ID, in five-bit digits, under `/var/folders`. A test checks it against `confstr` outside the sandbox.
- The sandbox treats connecting to a Unix socket as outbound networking, which `network.client` doesn't cover, and file exceptions don't help. The entitlements add one `com.apple.security.temporary-exception.sbpl` rule allowing `network-outbound` only to `discord-ipc-[0-9]` sockets in a `/var/folders/<id>/<id>/T/` folder, where the ids use macOS's folder alphabet (`[0-9a-z_]+`). The sandbox's regex engine doesn't accept counted repeats such as `{2}`; a rule using one silently matches nothing. Tempus only tries that folder, so other paths never produce sandbox denials.
- The Mac App Store rejects that exception. Tempus isn't distributed there; revisit if that changes.

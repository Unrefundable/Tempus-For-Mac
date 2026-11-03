# Tempus for macOS

A native macOS client for Subsonic, OpenSubsonic and Navidrome servers, written in Swift and SwiftUI. It is a port of [Tempus](https://github.com/eddyizm/tempus), the open-source Android music client.

**Status:** feature-complete for everyday use (Phases 0–9): library, Home, search, playback with gapless, ReplayGain and EQ, playlists, podcasts, radio, shares, downloads and offline play. Release packaging (Phase 10) is next. See [docs/PLAN.md](docs/PLAN.md) for the roadmap and [docs/adr/](docs/adr/) for design decisions.

## Layout

```
TempusMac/                  The macOS app
  Packages/TempusKit/       Swift package with the app's logic (API client, playback, ...)
  Spike/                    Throwaway experiments that informed design decisions
reference/tempus/           Upstream Android source, read-only (git submodule)
docs/                       Plan and architecture decision records
```

## Building

Requires Xcode 26 or newer and macOS 15 or newer. The upstream source is a submodule; fetch it after cloning:

```bash
git submodule update --init
```

```bash
cd TempusMac/Packages/TempusKit && swift test
```

To try the app without a real server, run the mock Subsonic server and add `http://127.0.0.1:4533` in Tempus (test account in the script's docstring; needs ffmpeg):

```bash
TempusMac/Packages/TempusKit/scripts/mock-subsonic.py
```

The icons, theme colors, fonts and app icon come from upstream. After updating the submodule, regenerate them from the repository root:

```bash
swift scripts/import-tempus-assets.swift reference/tempus
```

## License

Tempus for macOS is released under the [GNU General Public License v3.0](LICENSE), the same license as upstream Tempus, because it is a derivative work of it.

## Credits

- [Tempus](https://github.com/eddyizm/tempus) by [eddyizm](https://github.com/eddyizm) and contributors, the Android app this port is based on.
- [Tempo](https://github.com/CappielloAntonio/tempo) by [CappielloAntonio](https://github.com/CappielloAntonio), the project Tempus was forked from.
- [SeattleGuy](https://github.com/SeattleGuy) for the Tempus logo design. The icons, illustrations and app icon are upstream Tempus's drawables, converted to SVG.
- [Inter](https://github.com/rsms/inter) by The Inter Project Authors (SIL Open Font License 1.1), the typeface Tempus uses. Its license ships next to the fonts in `TempusKit/Sources/DesignSystem/Resources/Fonts/OFL.txt`.
- [Amperfy](https://github.com/BLeeEZ/amperfy) (GPL-3.0), whose player served as a reference for wiring AudioStreaming, the equalizer and ReplayGain.
- [AudioStreaming](https://github.com/dimitris-c/AudioStreaming) (MIT) for audio playback. A patched copy lives in `TempusMac/Vendor/AudioStreaming`; its `TEMPUS-PATCHES.md` lists the changes.

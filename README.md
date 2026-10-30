# Tempus for macOS

A native macOS client for Subsonic, OpenSubsonic and Navidrome servers, written in Swift and SwiftUI. It is a port of [Tempus](https://github.com/eddyizm/tempus), the open-source Android music client.

**Status:** early development. See [docs/PLAN.md](docs/PLAN.md) for the roadmap and [docs/adr/](docs/adr/) for design decisions.

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

## License

Tempus for macOS is released under the [GNU General Public License v3.0](LICENSE), the same license as upstream Tempus, because it is a derivative work of it.

## Credits

- [Tempus](https://github.com/eddyizm/tempus) by [eddyizm](https://github.com/eddyizm) and contributors, the Android app this port is based on.
- [Tempo](https://github.com/CappielloAntonio/tempo) by [CappielloAntonio](https://github.com/CappielloAntonio), the project Tempus was forked from.
- [SeattleGuy](https://github.com/SeattleGuy) for the Tempus logo design.
- [Amperfy](https://github.com/BLeeEZ/amperfy) (GPL-3.0), whose player served as a reference for wiring AudioStreaming, the equalizer and ReplayGain.
- [AudioStreaming](https://github.com/dimitris-c/AudioStreaming) (MIT) for audio playback.

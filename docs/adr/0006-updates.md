# ADR 0006: Updates from GitHub releases with Sparkle

- **Status:** Accepted
- **Date:** 2026-11-03

## Context

Tempus is distributed as a zip on GitHub releases. It should update itself from them, with a Settings switch for automatic updates and another for betas, which are GitHub pre-releases. Upstream Tempus has no equivalent: Android updates come from the store or F-Droid, and upstream's GitHub-flavor update check only links to the release page.

The app is sandboxed. A sandboxed process can't replace its own bundle, and every process it starts inherits the sandbox. Installing an update needs a helper outside the sandbox.

## Decisions

### 1. Sparkle 2, not a hand-written updater
- PLAN.md already names Sparkle. It is the standard Mac updater. It ships an installer XPC service that launchd runs outside the sandbox. That service replaces the app and clears the quarantine flag the sandbox puts on downloads.
- A hand-written updater would have to rebuild that installer, which is the hard part. Reading the GitHub Releases API directly is easy, but it doesn't solve installation.
- Sparkle comes from SwiftPM (2.10.1) and is linked by `TempusUI` only. Xcode embeds `Sparkle.framework` with its `Installer.xpc` automatically.
- `Info.plist` sets `SUEnableInstallerLauncherService`. The entitlements add the two `mach-lookup` exceptions (`$(PRODUCT_BUNDLE_IDENTIFIER)-spks`, `-spki`) that sandboxed Sparkle needs. The downloader service isn't needed, because the app already has `network.client`.

### 2. The feed is `appcast.xml` on `main`; the zips stay on the releases
- Sparkle reads an appcast, not the GitHub API. `SUFeedURL` is `https://raw.githubusercontent.com/Unrefundable/Tempus-For-Mac/main/appcast.xml`.
- Each item's enclosure is the release's zip asset.
- `releases/latest/download/appcast.xml` was rejected. "Latest" skips pre-releases, so beta testers would never see betas.
- **The repository must be public** for this to work. Raw files and release assets of a private repository need a GitHub token, and the app ships none.

### 3. Betas are a Sparkle channel
- A version with a semantic-versioning pre-release suffix (`0.2.0-beta.1`) is published in the `beta` channel. Stable versions go in the default channel.
- `SPUUpdaterDelegate.allowedChannels(for:)` returns `["beta"]` only while **Get beta updates** is on (`AppSettings.receivesBetaUpdates`).
- That switch defaults to on when the running build is itself a beta, so testers keep getting betas, and off otherwise. Turning it on checks straight away.
- Turning betas off doesn't downgrade. A beta user stays on their build until a stable release with a higher build number appears.

### 4. One switch for automatic updates
- **Download and install updates automatically** sets Sparkle's `automaticallyChecksForUpdates` and `automaticallyDownloadsUpdates` together. Sparkle checks daily, downloads in the background and installs when Tempus quits.
- Off, updates come only from **Tempus › Check for Updates…** or the Settings button.
- `SUEnableAutomaticChecks` and `SUAutomaticallyUpdate` make that the default, without Sparkle's first-launch permission prompt.
- Debug builds and `-TempusDemo` runs never start the updater, so an update can't replace a development build. Their switches are disabled.
- The updater starts even when the app model can't (a failed database open shows the startup error). A release that breaks launching can then still be fixed by the next one.

### 5. Updates and the feed are both signed with EdDSA
- `SUPublicEDKey` is in Info.plist. The private key lives in the release machine's login Keychain, made once with Sparkle's `generate_keys`. **Back it up** (`generate_keys -x <file>`). Losing it means existing installs can never be updated again.
- `SUVerifyUpdateBeforeExtraction` checks the zip's signature before unzipping.
- `SURequireSignedFeed` refuses an appcast that wasn't re-signed with `sign_update` after editing, so a tampered feed can't push a downgrade or a fake channel.

### 6. Releases are signed with the Apple Development identity, not ad hoc
- macOS ties a sandboxed app's container and its Keychain items to the code signature's designated requirement. An ad-hoc signature changes with every build, so each update would look like a different app: macOS would prompt for container access, and the Keychain would prompt for server passwords.
- `scripts/release.sh` signs with the team's Apple Development certificate, whose requirement stays the same across builds.
- Developer ID signing and notarization remain Phase 10 work. They need a paid Developer ID certificate. Until then, a first install still needs **Open Anyway**. Updates don't, because Sparkle clears the quarantine flag.

### 7. Publishing is one script
`scripts/release.sh <version> [--notes-file notes.md]`, run from a clean `main`:
1. It builds a universal Release app, with the build number set to the commit count so it only goes up.
2. It zips the app, signs the zip, adds the item with `scripts/add-appcast-item.swift` and re-signs the feed.
3. After a confirmation, it creates the GitHub release (marked as a pre-release for betas) and pushes `appcast.xml` to `main`.

The release goes up before the feed, so the feed never points at a zip that doesn't exist yet.

## Verification

An end-to-end run used a separate bundle id (`…TempusMac.updatetest`), a local feed and two builds, 0.9.0-beta.1 (100) and 0.9.1-beta.1 (101):
- With betas on, the old build downloaded the beta silently at launch. It was replaced in place when it quit, with a valid signature and no quarantine flag.
- With betas off, Check for Updates said the app was up to date.
- Turning betas back on started a background download right away.

## Consequences

- Builds before the first Sparkle release, including 0.1.0-beta.1, don't update themselves. Testers install the first Sparkle-enabled build by hand once.
- A release made by hand on GitHub's website isn't offered until its item is in `appcast.xml`. Use the script.
- `appcast.xml` must only change through the script (or `sign_update` after an edit), or every installed copy will reject the feed.

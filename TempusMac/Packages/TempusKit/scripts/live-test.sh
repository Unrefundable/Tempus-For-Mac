#!/bin/sh
# Runs the read-only live-server tests (Tests/SubsonicAPITests/LiveServerTests.swift) and the
# silent live playback test (Tests/PlaybackTests/LivePlaybackTests.swift) against
# your own Subsonic or Navidrome server. Nothing on the server is changed.
#
# Credentials are typed here, handed to the test process through its environment only, and
# never written to disk or printed. The password is not echoed while you type it.
set -eu
cd "$(dirname "$0")/.."

restore_echo() { stty echo 2>/dev/null || true; }
trap restore_echo EXIT INT TERM

printf 'Server URL (for example https://music.example.com): '
read -r TEMPUS_LIVE_SERVER
printf 'Local URL, if you use one at home (press Enter to skip): '
read -r TEMPUS_LIVE_LOCAL
printf 'Username: '
read -r TEMPUS_LIVE_USER
printf 'Password (not shown): '
stty -echo
read -r TEMPUS_LIVE_PASSWORD
restore_echo
printf '\n'
printf 'Send the password in plain text instead of a token? Only if token login fails. [y/N]: '
read -r plain
case "$plain" in [yY]*) TEMPUS_LIVE_PLAINTEXT=1 ;; *) TEMPUS_LIVE_PLAINTEXT=0 ;; esac

export TEMPUS_LIVE_SERVER TEMPUS_LIVE_LOCAL TEMPUS_LIVE_USER TEMPUS_LIVE_PASSWORD TEMPUS_LIVE_PLAINTEXT

printf '\nRunning read-only tests against your server...\n\n'
swift test --filter "LiveServerTests|LivePlaybackTests" 2>&1 | grep -vE '^\[[0-9]+/[0-9]+\]|^(Building|Build complete|Compiling|Write|Emitting)'

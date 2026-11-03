#!/bin/bash
# Builds, signs and publishes a Tempus release, so installed copies update themselves.
#
#   scripts/release.sh 0.2.0                          a stable release
#   scripts/release.sh 0.2.0-beta.1                   a pre-release, offered only with beta updates on
#   scripts/release.sh 0.2.0 --notes-file notes.md    release notes for GitHub (default: generated)
#
# It builds a universal Release app signed with the Apple Development identity, zips it, signs the
# zip with the Sparkle EdDSA key in your login Keychain (made once with Sparkle's generate_keys),
# then asks before publishing:
#   1. a GitHub release (marked pre-release for a beta) with the zip, and
#   2. the release's entry in appcast.xml, signed, committed and pushed to main.
# The app reads appcast.xml from main, so the release must exist before the push.
#
# Run it from a clean checkout of main. See docs/adr/0006-updates.md.

set -euo pipefail

REPO="Unrefundable/Tempus-For-Mac"
TEAM="TEAMID"
IDENTITY="Apple Development"

usage() {
    echo "Usage: scripts/release.sh <version> [--notes-file <file>]" >&2
    exit 64
}

[[ $# -ge 1 ]] || usage
VERSION=$1
shift
NOTES_FILE=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --notes-file) NOTES_FILE=${2:?}; shift 2 ;;
        *) usage ;;
    esac
done

[[ $VERSION =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?(-[0-9A-Za-z.]+)?$ ]] || {
    echo "Version must look like 1.2.3 or 1.2.3-beta.1, not '$VERSION'." >&2
    exit 64
}
if [[ -n $NOTES_FILE ]]; then
    [[ -f $NOTES_FILE ]] || { echo "No notes file at $NOTES_FILE." >&2; exit 66; }
    NOTES_FILE="$(cd "$(dirname "$NOTES_FILE")" && pwd)/$(basename "$NOTES_FILE")"
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

TAG="v$VERSION"
PRERELEASE=false
[[ $VERSION == *-* ]] && PRERELEASE=true

# Preflight: publishing pushes appcast.xml to main, so start from an up-to-date, clean main.
[[ $(git branch --show-current) == main ]] || { echo "Run this on main." >&2; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo "Commit or stash your changes first." >&2; exit 1; }
git fetch --quiet origin main
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || { echo "main isn't in sync with origin." >&2; exit 1; }
! git rev-parse --quiet --verify "refs/tags/$TAG" >/dev/null || { echo "Tag $TAG already exists." >&2; exit 1; }
! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 || { echo "Release $TAG already exists." >&2; exit 1; }

# Sparkle orders updates by build number, so it must only go up: the commit count does.
BUILD=$(git rev-list --count HEAD)
NEWEST=$(grep -o '<sparkle:version>[0-9]*' appcast.xml | grep -o '[0-9]*$' | sort -n | tail -1 || true)
[[ -z $NEWEST || $BUILD -gt $NEWEST ]] || {
    echo "Build $BUILD isn't newer than build $NEWEST in appcast.xml; commit something first." >&2
    exit 1
}
OUT="$ROOT/build/release-$VERSION"
DERIVED="$ROOT/build/DerivedData"
ZIP_NAME="Tempus-$VERSION-macOS.zip"
ZIP="$OUT/$ZIP_NAME"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "Building Tempus $VERSION ($BUILD)…"
xcodebuild -project TempusMac/TempusMac.xcodeproj -scheme Tempus -configuration Release \
    -derivedDataPath "$DERIVED" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
    CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
    ONLY_ACTIVE_ARCH=NO \
    clean build >"$OUT/build.log" 2>&1 || { echo "Build failed; see $OUT/build.log." >&2; exit 1; }

APP="$DERIVED/Build/Products/Release/Tempus.app"
codesign --verify --deep --strict "$APP"
[[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]] || { echo "Sparkle.framework isn't embedded." >&2; exit 1; }
# The container and Keychain items follow the signature, so every release must carry the team's.
codesign -dv "$APP" 2>&1 | grep -qx "TeamIdentifier=$TEAM" \
    || { echo "Tempus.app isn't signed by team $TEAM." >&2; exit 1; }
SHORT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
[[ $SHORT == "$VERSION" ]] || { echo "Built version $SHORT, expected $VERSION." >&2; exit 1; }
echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/Tempus")"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
SIGN_UPDATE="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
SIGNATURE=$("$SIGN_UPDATE" -p "$ZIP")
LENGTH=$(stat -f %z "$ZIP")
SHA256=$(shasum -a 256 "$ZIP" | cut -d ' ' -f 1)

URL="https://github.com/$REPO/releases/download/$TAG/$ZIP_NAME"
# Until the feed is committed, any failure puts it back, so the next run starts clean.
trap 'git checkout HEAD -- appcast.xml' EXIT
swift scripts/add-appcast-item.swift appcast.xml \
    --version "$VERSION" --build "$BUILD" --url "$URL" --length "$LENGTH" --signature "$SIGNATURE" \
    --notes "https://github.com/$REPO/releases/tag/$TAG"
"$SIGN_UPDATE" appcast.xml >/dev/null
"$SIGN_UPDATE" --verify appcast.xml >/dev/null

echo
echo "Ready: $ZIP"
echo "  SHA-256 $SHA256"
echo "  $([[ $PRERELEASE == true ]] && echo "Pre-release, beta channel" || echo "Stable release")"
read -r -p "Publish $TAG to GitHub and the update feed? [y/N] " answer
if [[ $answer != [yY] ]]; then
    echo "Not published. The zip is in $OUT."
    exit 0
fi

NOTES_ARGS=(--generate-notes)
[[ -n $NOTES_FILE ]] && NOTES_ARGS=(--notes-file "$NOTES_FILE")
PRERELEASE_ARGS=()
[[ $PRERELEASE == true ]] && PRERELEASE_ARGS=(--prerelease)
gh release create "$TAG" "$ZIP" --repo "$REPO" --target "$(git rev-parse HEAD)" \
    --title "Tempus for macOS $VERSION" "${NOTES_ARGS[@]}" "${PRERELEASE_ARGS[@]+"${PRERELEASE_ARGS[@]}"}"

git add appcast.xml
git commit --quiet -m "chore: publish $VERSION to the update feed"
trap - EXIT
git push --quiet origin main || {
    echo "The release is up but the feed isn't: push main again with 'git push origin main'." >&2
    exit 1
}
echo "Published $TAG. Installed copies pick it up at their next daily check."

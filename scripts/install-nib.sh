#!/usr/bin/env bash
# The Rune in daily use (2026-10-01; Nib until 2026-10-07): a Release build, team-signed as the Debug
# one is (so iCloud works on the team's registered Macs), installed as /Applications/Rune.app. The scenarios run
# their own Debug build from build/DerivedData, with a folder and settings of their own
# (Application Support/nib-scenarios, com.banastas.nib.scenarios), so rebuilding and testing
# never touch this copy. Its build number is the time it was built, higher than the Debug
# build's, so that macOS opens files with this copy and not a Debug one it also knows.
# Not Developer ID signed or notarized: scripts/release.sh INSTALL=1 makes and installs that copy (DS1).
#   scripts/install-nib.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
TARGET=/Applications/Rune.app
OLD=/Applications/Nib.app   # its name until 2026-10-07: the same app (one bundle ID), retired to the Trash
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Only ever replaces Rune (or the Nib it was), and not while it runs.
if [[ -e $TARGET ]] && [[ $(defaults read "$TARGET/Contents/Info" CFBundleIdentifier 2>/dev/null) != com.banastas.nib ]]; then
  echo "$TARGET is another app, not this Rune: move it aside first." >&2
  exit 1
fi
if pgrep -qf "$TARGET/Contents/MacOS/Rune"; then
  echo "Rune is running from $TARGET: quit it first (⌘Q), then run this again." >&2
  exit 1
fi
if pgrep -qf "$OLD/Contents/MacOS/Nib"; then
  echo "Nib is running from $OLD: quit it first (⌘Q), then run this again." >&2
  exit 1
fi

BUILD=$(date +%Y%m%d%H%M)
DERIVED=build/DerivedData-release
APP=$DERIVED/Build/Products/Release/Rune.app
echo "==> Building Rune (Release, team signing, build $BUILD)"
xcodebuild -project nib.xcodeproj -scheme nib -configuration Release -derivedDataPath "$DERIVED" \
  -destination "platform=macOS" -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD" -quiet build
# The sources as they are, as scripts/build-nib.sh checks for the Debug build.
stale=$(find nib NibKit/Sources -name '*.swift' -newer "$APP/Contents/MacOS/Rune" | head -1)
if [[ -n $stale ]]; then
  echo "The build is older than $stale: stopping." >&2
  exit 1
fi
codesign --verify --deep --strict "$APP"
# The third-party notices (DS3) follow what's built: said if they're behind it.
scripts/acknowledgements.py --check --checkouts "$DERIVED/SourcePackages/checkouts" >/dev/null 2>&1 \
  || echo "Note: About's acknowledgements are out of date: run scripts/acknowledgements.py, commit it, and install again."

echo "==> Installing $TARGET"
rm -rf "$TARGET.new"
ditto "$APP" "$TARGET.new"
rm -rf "$TARGET"
mv "$TARGET.new" "$TARGET"
"$LSREGISTER" -f "$TARGET"
# The copy under the old name, retired: to the Trash (Put Back works), unregistered first.
if [[ -d $OLD ]] && [[ $(defaults read "$OLD/Contents/Info" CFBundleIdentifier 2>/dev/null) == com.banastas.nib ]]; then
  "$LSREGISTER" -u "$OLD" 2>/dev/null || true
  mv "$OLD" "$HOME/.Trash/Nib $(date +%Y-%m-%d\ %H.%M.%S).app" && echo "Moved $OLD to the Trash: Rune is the same app under its new name."
fi
# The build's own copy isn't one for macOS to open files with.
"$LSREGISTER" -u "$PWD/$APP" 2>/dev/null || true
echo "Installed $TARGET: Rune $(defaults read "$TARGET/Contents/Info" CFBundleShortVersionString) ($BUILD), from $(git rev-parse --short HEAD)$(git diff --quiet HEAD -- nib NibKit || echo ', with changes not committed')."
echo "Open it from /Applications. Quit any Debug build of Rune first: two at once would hold the same files."

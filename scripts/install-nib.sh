#!/usr/bin/env bash
# The Nib in daily use (2026-10-01): a Release build, team-signed as the Debug one is (so iCloud
# works on the team's registered Macs), installed as /Applications/Nib.app. The scenarios run
# their own Debug build from build/DerivedData, with a folder and settings of their own
# (Application Support/nib-scenarios, com.banastas.nib.scenarios), so rebuilding and testing
# never touch this copy. Its build number is the time it was built, higher than the Debug
# build's, so that macOS opens files with this copy and not a Debug one it also knows.
# Not Developer ID signed or notarized: that's DS1, with the user's certificates.
#   scripts/install-nib.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
TARGET=/Applications/Nib.app
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Only ever replaces Nib, and not while it runs.
if [[ -e $TARGET ]] && [[ $(defaults read "$TARGET/Contents/Info" CFBundleIdentifier 2>/dev/null) != com.banastas.nib ]]; then
  echo "$TARGET is another app, not this Nib: move it aside first." >&2
  exit 1
fi
if pgrep -qf "$TARGET/Contents/MacOS/Nib"; then
  echo "Nib is running from $TARGET: quit it first (⌘Q), then run this again." >&2
  exit 1
fi

BUILD=$(date +%Y%m%d%H%M)
DERIVED=build/DerivedData-release
APP=$DERIVED/Build/Products/Release/Nib.app
echo "==> Building Nib (Release, team signing, build $BUILD)"
xcodebuild -project nib.xcodeproj -scheme nib -configuration Release -derivedDataPath "$DERIVED" \
  -destination "platform=macOS" -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD" -quiet build
# The sources as they are, as scripts/build-nib.sh checks for the Debug build.
stale=$(find nib NibKit/Sources -name '*.swift' -newer "$APP/Contents/MacOS/Nib" | head -1)
if [[ -n $stale ]]; then
  echo "The build is older than $stale: stopping." >&2
  exit 1
fi
codesign --verify --deep --strict "$APP"

echo "==> Installing $TARGET"
rm -rf "$TARGET.new"
ditto "$APP" "$TARGET.new"
rm -rf "$TARGET"
mv "$TARGET.new" "$TARGET"
"$LSREGISTER" -f "$TARGET"
# The build's own copy isn't one for macOS to open files with.
"$LSREGISTER" -u "$PWD/$APP" 2>/dev/null || true
echo "Installed $TARGET: Nib $(defaults read "$TARGET/Contents/Info" CFBundleShortVersionString) ($BUILD), from $(git rev-parse --short HEAD)$(git diff --quiet HEAD -- nib NibKit || echo ', with changes not committed')."
echo "Open it from /Applications. Quit any Debug build of Nib first: two at once would hold the same files."

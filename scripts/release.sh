#!/usr/bin/env bash
# release.sh — builds Nib.app signed with Developer ID, notarizes it with Apple, staples the
# ticket and zips it (PRD DS1, T6); INSTALL=1 puts it in /Applications. From Blit's
# scripts/release.sh (2026-10-07); Nib's own since. Sparkle's PUBLISH step comes with DS2.
#
# What it needs, once (your steps: they're your account's):
#   - Xcode signed in to the team's account (Xcode › Settings › Accounts): the export signs with
#     the team's Developer ID certificate (a cloud-managed one if this Mac has none) and makes a
#     Developer ID provisioning profile with Nib's iCloud container, iCloud.com.banastas.nib.
#   - Notary credentials in the Keychain. Blit's are the team's and work for Nib too:
#       xcrun notarytool store-credentials blit-notary --apple-id you@example.com --team-id F87BNUZAVJ
#
# Usage:
#   scripts/release.sh                  # build, notarize, staple → build/release/
#   INSTALL=1 scripts/release.sh        # …then replace /Applications/Nib.app (quit Nib first)
#   SKIP_NOTARIZE=1 scripts/release.sh  # sign and export only
#
# Environment: NOTARY_PROFILE (default blit-notary), OUT (default build/release)
#
# Its build number is the time, as scripts/install-nib.sh's is: higher than the Debug build's
# (so macOS opens files with it) and rising from one release to the next (as Sparkle needs).
# The Developer ID copy has the same bundle ID and iCloud container as the team-signed one, so
# its folder, settings and History are the same; macOS may ask again for what it asked the
# other copy (Finder for Empty Trash, folders), its signature being another.

set -euo pipefail
cd "$(dirname "$0")/.."

TEAM=F87BNUZAVJ
CONTAINER=iCloud.com.banastas.nib
PROFILE=${NOTARY_PROFILE:-blit-notary}
OUT=${OUT:-build/release}
DERIVED=build/DerivedData-archive
TARGET=/Applications/Nib.app
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

# Only ever replaces Nib, and not while it runs: asked first, before the build's minutes.
if [[ "${INSTALL:-0}" == 1 ]]; then
  if [[ -e $TARGET ]] && [[ $(defaults read "$TARGET/Contents/Info" CFBundleIdentifier 2>/dev/null) != com.banastas.nib ]]; then
    echo "$TARGET is another app, not Nib: move it aside first." >&2
    exit 1
  fi
  if pgrep -qf "$TARGET/Contents/MacOS/Nib"; then
    echo "Nib is running from $TARGET: quit it first (⌘Q), then run this again." >&2
    exit 1
  fi
fi

rm -rf "$OUT"
mkdir -p "$OUT"
BUILD=$(date +%Y%m%d%H%M)

echo "==> Archiving Nib (Release, build $BUILD)"
xcodebuild -project nib.xcodeproj -scheme nib -configuration Release \
  -archivePath "$OUT/Nib.xcarchive" -derivedDataPath "$DERIVED" -destination 'generic/platform=macOS' \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD" -quiet archive
ARCHIVED="$OUT/Nib.xcarchive/Products/Applications/Nib.app"
# The sources as they are, as scripts/build-nib.sh checks for the Debug build.
stale=$(find nib NibKit/Sources -name '*.swift' -newer "$ARCHIVED/Contents/MacOS/Nib" | head -1)
if [[ -n $stale ]]; then
  echo "The archive is older than $stale: stopping." >&2
  exit 1
fi
# The third-party notices (DS3) follow what's built: said if they're behind it.
scripts/acknowledgements.py --check --checkouts "$DERIVED/SourcePackages/checkouts" >/dev/null 2>&1 \
  || echo "    Note: About's acknowledgements are out of date: run scripts/acknowledgements.py, commit it, and release again."

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST

echo "==> Exporting with Developer ID"
xcodebuild -exportArchive -archivePath "$OUT/Nib.xcarchive" -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT" -allowProvisioningUpdates -quiet

APP="$OUT/Nib.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
codesign --verify --deep --strict "$APP"
SIGNED=$(codesign -dvv "$APP" 2>&1)   # -vv: the authorities (-v shows none)
grep -E "^Authority=Developer ID|^TeamIdentifier|runtime" <<<"$SIGNED" || true
grep -q "^Authority=Developer ID Application" <<<"$SIGNED" || { echo "Not signed with Developer ID: stopping." >&2; exit 1; }
# Nib's iCloud folder (§4.2) needs its container in the signature and a Developer ID profile
# that allows it (PRD M0's open question: whether iCloud Documents works under Developer ID).
codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "$CONTAINER" \
  || { echo "The signature has no $CONTAINER entitlement: Nib's iCloud folder wouldn't open. Stopping." >&2; exit 1; }
PROVISION=$(security cms -D -i "$APP/Contents/embedded.provisionprofile" 2>/dev/null || true)
if [[ -z $PROVISION ]] || ! grep -q "$CONTAINER" <<<"$PROVISION"; then
  echo "No embedded provisioning profile with $CONTAINER: Nib's iCloud folder wouldn't open. Stopping." >&2
  exit 1
fi
echo "    Profile: $(plutil -extract Name raw -o - - <<<"$PROVISION" 2>/dev/null || echo unnamed), with $CONTAINER"

if [[ "${SKIP_NOTARIZE:-0}" != 1 ]]; then
  echo "==> Notarizing (this usually takes a few minutes)"
  ditto -c -k --keepParent "$APP" "$OUT/Nib-notarize.zip"
  xcrun notarytool submit "$OUT/Nib-notarize.zip" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$OUT/Nib-notarize.zip"
  spctl --assess --type execute -vv "$APP"
fi

ZIP="$OUT/Nib-$VERSION-$BUILD.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "==> $ZIP"

if [[ "${INSTALL:-0}" == 1 ]]; then
  echo "==> Installing $TARGET"
  rm -rf "$TARGET.new"
  ditto "$APP" "$TARGET.new"
  rm -rf "$TARGET"
  mv "$TARGET.new" "$TARGET"
  "$LSREGISTER" -f "$TARGET"
  echo "Installed $TARGET: Nib $VERSION ($BUILD), from $(git rev-parse --short HEAD)$(git diff --quiet HEAD -- nib NibKit || echo ', with changes not committed'). Open it from /Applications."
fi

# Only the installed copy should be one macOS opens files with: not the export's or the archive's.
for copy in "$APP" "$ARCHIVED" "$DERIVED"/Build/Intermediates.noindex/ArchiveIntermediates/nib/InstallationBuildProductsLocation/Applications/Nib.app; do
  if [[ -d "$copy" ]]; then "$LSREGISTER" -u "$PWD/$copy" >/dev/null 2>&1 || "$LSREGISTER" -u "$copy" >/dev/null 2>&1 || true; fi
done

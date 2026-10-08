#!/usr/bin/env bash
# release.sh — builds Rune.app (Nib.app until 2026-10-07) signed with Developer ID, notarizes
# it with Apple, staples the ticket and zips it (PRD DS1, T6); INSTALL=1 puts it in /Applications,
# retiring the old Nib.app. From Blit's scripts/release.sh (2026-10-07); Rune's own since. Sparkle's
# PUBLISH step comes with DS2.
#
# What it needs, once (your steps: they're your account's):
#   - Xcode signed in to the team's account (Xcode › Settings › Accounts): the export signs with
#     the team's Developer ID certificate (a cloud-managed one if this Mac has none) and makes a
#     Developer ID provisioning profile with its iCloud container, iCloud.com.banastas.nib.
#   - Notary credentials in the Keychain. Blit's are the team's and work for Rune too:
#       xcrun notarytool store-credentials blit-notary --apple-id you@example.com --team-id F87BNUZAVJ
#
# Usage:
#   scripts/release.sh                  # build, notarize, staple → build/release/
#   INSTALL=1 scripts/release.sh        # …then replace /Applications/Rune.app (quit it first)
#   SKIP_NOTARIZE=1 scripts/release.sh  # sign and export only
#   VERSION=0.2 …                       # the version shown (CFBundleShortVersionString; the project's otherwise)
#   PUBLISH=1 INSTALL=1 NOTES="What changed" scripts/release.sh
#                                       # …then publish it as an update (DS2): sign the zip for Sparkle
#                                       # (the EdDSA key in this Mac's Keychain, Blit's), put it in
#                                       # site/downloads/, write site/appcast.xml, commit those two and push
#                                       # (Cloudflare Pages deploys site/ to rune.banast.as)
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
TARGET=/Applications/Rune.app
OLD=/Applications/Nib.app   # its name until 2026-10-07: the same app (one bundle ID), retired to the Trash
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

# Only ever replaces Rune (or the Nib it was), and not while it runs: asked first, before the build's minutes.
if [[ "${INSTALL:-0}" == 1 ]]; then
  if [[ -e $TARGET ]] && [[ $(defaults read "$TARGET/Contents/Info" CFBundleIdentifier 2>/dev/null) != com.banastas.nib ]]; then
    echo "$TARGET is another app, not Rune: move it aside first." >&2
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
fi

rm -rf "$OUT"
mkdir -p "$OUT"
BUILD=$(date +%Y%m%d%H%M)

echo "==> Archiving Rune (Release, build $BUILD${VERSION:+, version $VERSION})"
xcodebuild -project nib.xcodeproj -scheme nib -configuration Release \
  -archivePath "$OUT/Rune.xcarchive" -derivedDataPath "$DERIVED" -destination 'generic/platform=macOS' \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD" ${VERSION:+MARKETING_VERSION="$VERSION"} -quiet archive
ARCHIVED="$OUT/Rune.xcarchive/Products/Applications/Rune.app"
# The sources as they are, as scripts/build-nib.sh checks for the Debug build.
stale=$(find nib NibKit/Sources -name '*.swift' -newer "$ARCHIVED/Contents/MacOS/Rune" | head -1)
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
xcodebuild -exportArchive -archivePath "$OUT/Rune.xcarchive" -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT" -allowProvisioningUpdates -quiet

APP="$OUT/Rune.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
codesign --verify --deep --strict "$APP"
SIGNED=$(codesign -dvv "$APP" 2>&1)   # -vv: the authorities (-v shows none)
grep -E "^Authority=Developer ID|^TeamIdentifier|runtime" <<<"$SIGNED" || true
grep -q "^Authority=Developer ID Application" <<<"$SIGNED" || { echo "Not signed with Developer ID: stopping." >&2; exit 1; }
# Its iCloud folder (§4.2) needs its container in the signature and a Developer ID profile
# that allows it (PRD M0's open question: whether iCloud Documents works under Developer ID).
codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "$CONTAINER" \
  || { echo "The signature has no $CONTAINER entitlement: its iCloud folder wouldn't open. Stopping." >&2; exit 1; }
PROVISION=$(security cms -D -i "$APP/Contents/embedded.provisionprofile" 2>/dev/null || true)
if [[ -z $PROVISION ]] || ! grep -q "$CONTAINER" <<<"$PROVISION"; then
  echo "No embedded provisioning profile with $CONTAINER: its iCloud folder wouldn't open. Stopping." >&2
  exit 1
fi
echo "    Profile: $(plutil -extract Name raw -o - - <<<"$PROVISION" 2>/dev/null || echo unnamed), with $CONTAINER"

if [[ "${SKIP_NOTARIZE:-0}" != 1 ]]; then
  echo "==> Notarizing (this usually takes a few minutes)"
  ditto -c -k --keepParent "$APP" "$OUT/Rune-notarize.zip"
  xcrun notarytool submit "$OUT/Rune-notarize.zip" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$OUT/Rune-notarize.zip"
  spctl --assess --type execute -vv "$APP"
fi

ZIP="$OUT/Rune-$VERSION-$BUILD.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "==> $ZIP"

if [[ "${PUBLISH:-0}" == 1 ]]; then
  [[ "${SKIP_NOTARIZE:-0}" == 1 ]] && { echo "PUBLISH needs a notarized build" >&2; exit 1; }
  echo "==> Publishing $VERSION ($BUILD) as an update"
  # Sparkle's tools come with the Sparkle package the archive resolved.
  SPARKLE_BIN=$(ls -d "$DERIVED"/SourcePackages/artifacts/sparkle/Sparkle/bin 2>/dev/null | head -1)
  [[ -x "$SPARKLE_BIN/sign_update" ]] || { echo "Sparkle's sign_update not found under $DERIVED" >&2; exit 1; }
  # The EdDSA signature and length, signed with the key in this Mac's Keychain (Blit's).
  SIGNATURE=$("$SPARKLE_BIN/sign_update" "$ZIP")
  MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist" 2>/dev/null || echo "27.0")
  NAME="Rune-$VERSION-$BUILD.zip"   # a name of its own: one served from a cache under an old name wouldn't match its signature
  mkdir -p site/downloads
  rm -f site/downloads/Rune-*.zip            # the site keeps the current release only
  cp "$ZIP" "site/downloads/$NAME"
  cp "$ZIP" site/downloads/Rune.zip          # a stable name for the Download button
  NOTES_HTML=$(printf '%s' "${NOTES:-Fixes and improvements.}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
  cat > site/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Rune</title>
    <link>https://rune.banast.as/appcast.xml</link>
    <description>Updates for Rune</description>
    <language>en</language>
    <item>
      <title>Rune $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <description><![CDATA[<p>$NOTES_HTML</p>]]></description>
      <enclosure url="https://rune.banast.as/downloads/$NAME" type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
XML
  git add site/downloads site/appcast.xml
  git commit -q -m "Publish Rune $VERSION ($BUILD)" -- site/downloads site/appcast.xml
  git push -q
  echo "==> Published: https://rune.banast.as/downloads/$NAME (Cloudflare Pages deploys it in about a minute)"
fi

if [[ "${INSTALL:-0}" == 1 ]]; then
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
  echo "Installed $TARGET: Rune $VERSION ($BUILD), from $(git rev-parse --short HEAD)$(git diff --quiet HEAD -- nib NibKit || echo ', with changes not committed'). Open it from /Applications."
fi

# Only the installed copy should be one macOS opens files with: not the export's or the archive's.
for copy in "$APP" "$ARCHIVED" "$DERIVED"/Build/Intermediates.noindex/ArchiveIntermediates/nib/InstallationBuildProductsLocation/Applications/Rune.app; do
  if [[ -d "$copy" ]]; then "$LSREGISTER" -u "$PWD/$copy" >/dev/null 2>&1 || "$LSREGISTER" -u "$copy" >/dev/null 2>&1 || true; fi
done

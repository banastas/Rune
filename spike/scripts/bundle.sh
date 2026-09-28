#!/usr/bin/env bash
# Wraps the release build in NibSpike.app (ad-hoc signed): FileManager's sync
# controls need an app identity; a bare binary gets "feature not supported".
set -euo pipefail
cd "$(dirname "$0")/.."
APP=.build/NibSpike.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/nib-spike "$APP/Contents/MacOS/nib-spike"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.banastas.nib.spike</string>
<key>CFBundleName</key><string>NibSpike</string>
<key>CFBundleExecutable</key><string>nib-spike</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.0.1</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force -s - "$APP"
echo "$APP"

#!/usr/bin/env bash
# Builds the Debug app for the scenario scripts, and makes sure it's the sources as they are.
# On 2026-09-29 `-scheme nib` said "BUILD SUCCEEDED" and built only NibKit's command-line tool,
# then a product also called `nib` (it's `nib-cli` now), and a suite ran an app older than its
# code (PRD §8). If any Swift source is newer than the app after the build, it builds again
# from a fresh build database; if the app is still older, this stops.
#   scripts/build-nib.sh [team|adhoc]
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
SIGN=${1:-team}
BINARY=build/DerivedData/Build/Products/Debug/Nib.app/Contents/MacOS/Nib.debug.dylib

build() {
  if [[ $SIGN == adhoc ]]; then
    xcodebuild -project nib.xcodeproj -scheme nib -configuration Debug -derivedDataPath build/DerivedData \
      -destination "platform=macOS" CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
      CODE_SIGN_ENTITLEMENTS= -quiet build
  else
    xcodebuild -project nib.xcodeproj -scheme nib -configuration Debug -derivedDataPath build/DerivedData \
      -destination "platform=macOS" -allowProvisioningUpdates -quiet build
  fi
}

newer() { [[ -f $BINARY ]] || { echo nib/NibApp.swift; return; }; find nib NibKit/Sources -name '*.swift' -newer "$BINARY" 2>/dev/null; }

build
stale=$(newer)
if [[ -n $stale ]]; then
  echo "==> The app is older than $(echo "$stale" | wc -l | tr -d ' ') source file(s) ($(echo "$stale" | head -1)): building again"
  rm -f build/DerivedData/Build/Intermediates.noindex/XCBuildData/build.db   # it looks at every file again
  build
  stale=$(newer)
  if [[ -n $stale ]]; then
    echo "FAIL the build is still older than $(echo "$stale" | head -1): Xcode didn't rebuild; try again, or remove build/DerivedData"
    exit 1
  fi
fi

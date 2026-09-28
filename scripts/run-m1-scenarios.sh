#!/usr/bin/env bash
# M1's single-Mac checks (PRD §8): builds the Debug app and runs every scenario in
# nib/Model/TestHarness.swift against the scratch test file in iCloud Drive/nib-spike/.
# Prints PASS/FAIL lines; exits non-zero if anything failed. Takes about a minute.
# A nib window appears briefly for each scenario.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

echo "==> NibKit tests"
(cd NibKit && swift test 2>&1 | grep -E "Test run with|error:" | sed "s/\x1b\[[0-9;]*m//g" || true)

echo "==> Building nib (Debug, ad-hoc signed)"
xcodebuild -project nib.xcodeproj -scheme nib -configuration Debug -derivedDataPath build/DerivedData \
  -destination "platform=macOS" CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= -quiet build
APP=build/DerivedData/Build/Products/Debug/nib.app/Contents/MacOS/nib
LOGS=build/scenarios
mkdir -p "$LOGS"

run() {   # run <name> [args…]: one scenario, killed after 120 s if it hangs
  local name=$1; shift
  "$APP" -NibScenario "$name" -NibScenarioLog "$PWD/$LOGS/$name.log" "$@" >/dev/null 2>&1 &
  local pid=$!
  ( sleep 120; kill "$pid" 2>/dev/null ) & local guard=$!
  disown "$guard"
  wait "$pid" 2>/dev/null || true
  kill "$guard" 2>/dev/null || true
  echo "==> $name"
  grep -E "PASS|FAIL|after the last" "$LOGS/$name.log" || echo "FAIL no output"
}

marker="crash-$(date +%s)"
run type
run clipboard
run undo
run crash -NibMarker "$marker" -NibSaveIdle 600 -NibSaveMax 600
run recover -NibMarker "$marker"
run external -NibSaveIdle 600 -NibSaveMax 600

echo "==> Paused files left behind: $(cat "$HOME/Library/Application Support/nib/paused.json" 2>/dev/null || echo none)"
if grep -q "FAIL" "$LOGS"/*.log; then echo "SOME CHECKS FAILED"; exit 1; fi
echo "ALL CHECKS PASSED"

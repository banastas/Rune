#!/usr/bin/env bash
# M1's single-Mac checks (PRD §8): builds the Debug app and runs every scenario in
# nib/Model/TestHarness.swift against the scratch test file (iCloud Drive/Nib/Test/, or
# iCloud Drive/nib-spike/ with SIGN=adhoc).
# Prints PASS/FAIL lines; exits non-zero if anything failed. Takes about a minute.
# A nib window appears briefly for each scenario.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

echo "==> NibKit tests"
(cd NibKit && swift test 2>&1 | grep -E "Test run with|error:" | sed "s/\x1b\[[0-9;]*m//g" || true)

# SIGN=team (default): signed with the developer team, so nib gets its iCloud folder
# (iCloud Drive/Nib/Test/). Needs Xcode signed in to the Apple account on this Mac.
# SIGN=adhoc: no account needed, no iCloud container; tests run in iCloud Drive/nib-spike/.
SIGN=${SIGN:-team}
echo "==> Building nib (Debug, $SIGN signing)"
if [[ $SIGN == adhoc ]]; then
  xcodebuild -project nib.xcodeproj -scheme nib -configuration Debug -derivedDataPath build/DerivedData \
    -destination "platform=macOS" CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    CODE_SIGN_ENTITLEMENTS= -quiet build
else
  xcodebuild -project nib.xcodeproj -scheme nib -configuration Debug -derivedDataPath build/DerivedData \
    -destination "platform=macOS" -allowProvisioningUpdates -quiet build
fi
APP=build/DerivedData/Build/Products/Debug/Nib.app/Contents/MacOS/Nib

# A fresh test file (generated text): earlier runs leave conflict blocks in it, and the
# banner and the scenarios would see them all.
if [[ $SIGN == adhoc ]]; then TESTFILE="$HOME/Library/Mobile Documents/com~apple~CloudDocs/nib-spike/scratch-test.md"
else TESTFILE="$HOME/Library/Mobile Documents/iCloud~com~banastas~nib/Documents/Test/scratch-test.md"; fi
mkdir -p "$(dirname "$TESTFILE")"
printf 'Nib test file: generated text for the scenarios, started afresh by run-m1-scenarios.sh at %s.\n' "$(date '+%Y-%m-%d %H:%M:%S')" > "$TESTFILE"
LOGS=build/scenarios
mkdir -p "$LOGS"

run() {   # run <name> [args…]: one scenario, killed after 120 s if it hangs
  local name=$1; shift
  "$APP" -NibScenario "$name" -NibScenarioLog "$PWD/$LOGS/$name.log" "$@" >/dev/null 2>&1 &
  local pid=$!
  # The guard's output goes nowhere, or its sleep would hold a pipe open for 120 s.
  ( sleep 120; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 & local guard=$!
  disown "$guard"
  wait "$pid" 2>/dev/null || true
  pkill -P "$guard" sleep 2>/dev/null; kill "$guard" 2>/dev/null || true
  echo "==> $name"
  grep -E "PASS|FAIL|after the last" "$LOGS/$name.log" || echo "FAIL no output"
}

# A clean start: until M1 passes, nib opens only test files, so its journal holds only
# test-file snapshots (a failed earlier run can leave one that raises a conflict at launch).
rm -f "$HOME/Library/Application Support/nib/Journal/"*.json

marker="crash-$(date +%s)"
run type
run clipboard
run undo
run crash -NibMarker "$marker" -NibSaveIdle 600 -NibSaveMax 600
run recover -NibMarker "$marker"
run external -NibSaveIdle 600 -NibSaveMax 600
run unsent -NibHoldUploads YES
run merge
run mergeview
run duplicates
run conflictversions
run history
run files
run syntax
run themes
run synclog
umarker="untitled-$(date +%s)"
run untitled -NibMarker "$umarker" -NibSaveIdle 600 -NibSaveMax 600
run untitled-return -NibMarker "$umarker"
run untitled-quit -NibMarker "$umarker"
run refresh

echo "==> Paused files left behind: $(cat "$HOME/Library/Application Support/nib/paused.json" 2>/dev/null || echo none)"
failed=0
for name in type clipboard undo crash recover external unsent merge mergeview duplicates conflictversions history files syntax themes synclog untitled untitled-return untitled-quit refresh; do   # this run's logs only
  grep -q "FAIL" "$LOGS/$name.log" 2>/dev/null && failed=1
done
if (( failed )); then echo "SOME CHECKS FAILED"; exit 1; fi
echo "ALL CHECKS PASSED"

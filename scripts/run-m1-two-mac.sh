#!/usr/bin/env bash
# M1's two-Mac checks (PRD §8): the same test file open in nib on both Macs.
# Run the same line on both, with the same start time (HH:MM, at least two minutes ahead):
#
#   Mac A:  scripts/run-m1-two-mac.sh a 08:40
#   Mac B:  scripts/run-m1-two-mac.sh b 08:40
#
# Mac A adds a line; Mac B, untouched, must show it (by itself, or once it comes forward).
# Then both add a line at the same moment; the Mac whose upload is refused merges (Keep Both);
# both must end with both lines, the same bytes, synced. About 2.5 minutes after the start.
set -euo pipefail
cd "$(dirname "$0")/.."
role=${1:?usage: run-m1-two-mac.sh a|b HH:MM}
at=${2:?usage: run-m1-two-mac.sh a|b HH:MM}
[[ $role == a || $role == b ]] || { echo "role is a or b"; exit 2; }
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
T0=$(date -j -f "%H:%M:%S" "$at:00" +%s)
(( T0 > $(date +%s) + 60 )) || { echo "start time $at is less than a minute away (or past)"; exit 2; }

echo "==> Building nib (Debug, ad-hoc signed)"
xcodebuild -project nib.xcodeproj -scheme nib -configuration Debug -derivedDataPath build/DerivedData \
  -destination "platform=macOS" CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= -quiet build
APP=build/DerivedData/Build/Products/Debug/nib.app/Contents/MacOS/nib
mkdir -p build/scenarios
LOG=$PWD/build/scenarios/two-mac-$role.log

# Open the file a minute early, so both Macs hold it before anything happens.
wait=$(( T0 - 60 - $(date +%s) )); (( wait > 0 )) && { echo "==> Opening nib at $(date -r $((T0 - 60)) +%H:%M:%S)"; sleep "$wait"; }
echo "==> [$(date +%H:%M:%S)] nib on $(scutil --get ComputerName), role $role; start $at"
"$APP" -NibScenario two-mac -NibRole "$role" -NibAt "$T0" -NibMarker "m-$T0" -NibScenarioLog "$LOG" >/dev/null 2>&1 || true
echo
echo "================ paste this ================"
echo "M1 two-Mac · role $role · $(scutil --get ComputerName)"
grep -E "PASS|FAIL|SHA-256|conflict sheet" "$LOG" || echo "no output"

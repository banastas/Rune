#!/usr/bin/env bash
# What Nib writes, and which of its code writes it (PRD §8, the disk-writes report of 2026-10-02):
# the `writes` scenario on a generated Markdown file in the test folder (2.4 MB, or the size
# given), opened, typed in at its end and near its top, a minute idle, a check for another Mac's
# note, another Mac's version taken in, and closed. Prints each MEASURED line: this process's writes as the kernel counts
# them (logical: what the disk-writes limit counts), Nib's writers' share, the footprint.
# Six to eleven minutes (a save after one of 2.4 MB waits 30 s). It uses the test folder and
# Application Support/nib-scenarios as the suite does: not while a suite or the two-Mac test runs.
#   scripts/run-writes.sh [bytes]
#   NIB_APP=build/DerivedData-before/Build/Products/Debug/Rune.app/Contents/MacOS/Rune scripts/run-writes.sh
#     (an app built elsewhere, as it is: to compare two builds)
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
SIZE=${1:-2400000}
if [[ -n ${NIB_APP:-} ]]; then
  APP=$NIB_APP
else
  echo "==> Building nib (Debug, team signing)"
  scripts/build-nib.sh team
  APP=build/DerivedData/Build/Products/Debug/Rune.app/Contents/MacOS/Rune
fi
LOGS=build/scenarios
mkdir -p "$LOGS"
LOG="$LOGS/writes-$SIZE${NIB_APP:+-$(echo "$NIB_APP" | sed -E 's#.*/(DerivedData[^/]*)/.*#\1#')}.log"
rm -f "$LOG"
"$APP" -NibScenario writes -NibScenarioLog "$PWD/$LOG" -NibMarker "writes-$(date +%s)" -NibWritesSize "$SIZE" >/dev/null 2>&1 &
pid=$!
( sleep 900; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 & guard=$!
disown "$guard"
wait "$pid" 2>/dev/null || true
pkill -P "$guard" sleep 2>/dev/null || true; kill "$guard" 2>/dev/null || true
echo "==> writes ($SIZE bytes)"
grep -E "MEASURED|PASS|FAIL|open:" "$LOG" || echo "FAIL no output"

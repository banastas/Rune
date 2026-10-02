#!/usr/bin/env bash
# M1's two-Mac checks (PRD §8): the same test file open in nib on both Macs.
# Run the same line on both, with the same start time (HH:MM, at least two minutes ahead):
#
#   Mac A:  scripts/run-m1-two-mac.sh a 08:40
#   Mac B:  scripts/run-m1-two-mac.sh b 08:40
#
# Mac A adds a line; Mac B, untouched, must show it (by itself, or once it comes forward).
# Then both add a line at the same moment in the same place; the Mac whose upload is refused
# merges (Keep Both). Then both add a line at the same moment in different places, a at the top,
# b at the bottom: the refused Mac merges without a sheet. Both must end with every line once,
# the same bytes, synced. About 3.5 minutes after the start.
#
# With `remote` after the time, the remote probe instead (SY12, §4.8 E): a opens four test files;
# b, as Finder on the other Mac, moves one to the Trash, deletes one, renames one, and renames
# the folder of the fourth; a says what iCloud brings it and what Nib shows. About 4.5 minutes.
set -euo pipefail
cd "$(dirname "$0")/.."
role=${1:?usage: run-m1-two-mac.sh a|b HH:MM [remote]}
at=${2:?usage: run-m1-two-mac.sh a|b HH:MM [remote]}
probe=${3:-}
[[ $role == a || $role == b ]] || { echo "role is a or b"; exit 2; }
[[ -z $probe || $probe == remote ]] || { echo "the third word, if any, is: remote"; exit 2; }
scenario=two-mac${probe:+-$probe}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
T0=$(date -j -f "%H:%M:%S" "$at:00" +%s)
(( T0 > $(date +%s) + 60 )) || { echo "start time $at is less than a minute away (or past)"; exit 2; }

SIGN=${SIGN:-team}   # as in run-m1-scenarios.sh; both Macs must use the same
echo "==> Building nib (Debug, $SIGN signing)"
scripts/build-nib.sh "$SIGN"   # and checks the app is newer than every source file
APP=build/DerivedData/Build/Products/Debug/Nib.app/Contents/MacOS/Nib
mkdir -p build/scenarios
LOG=$PWD/build/scenarios/$scenario-$role.log
# A clean start for the scenarios' own journal: one left by an earlier failed run would raise a
# conflict at launch. (A scenario's Nib keeps its journal apart from the Nib in daily use's.)
rm -f "$HOME/Library/Application Support/nib-scenarios/Journal/"*.json

# Awake until this script ends: a sleeping Mac doesn't count time in `sleep`, and at 10:40 on
# 2026-09-29 the Air woke six minutes after the start and ran every phase at once, alone.
# (A closed lid on battery still sleeps.)
caffeinate -dis -w $$ &
# Open the file a minute early, so both Macs hold it before anything happens; wait by the clock.
if (( $(date +%s) < T0 - 60 )); then
  echo "==> Opening nib at $(date -r $((T0 - 60)) +%H:%M:%S)"
  while (( $(date +%s) < T0 - 60 )); do sleep 1; done
fi
late=$(( $(date +%s) - (T0 - 60) ))
if (( late > 30 )); then
  echo "==> It's $(date +%H:%M:%S), ${late} s after nib should have opened (was this Mac asleep?): too late for a start at $at."
  echo "    Not running: the other Mac's run won't find this one. Pick a new time on both."
  exit 3
fi
echo "==> [$(date +%H:%M:%S)] nib on $(scutil --get ComputerName), role $role; start $at"
"$APP" -NibScenario "$scenario" -NibRole "$role" -NibAt "$T0" -NibMarker "m-$T0" -NibScenarioLog "$LOG" >/dev/null 2>&1 || true
echo
echo "================ paste this ================"
if [[ -n $probe ]]; then
  echo "Two-Mac remote probe · role $role · $(scutil --get ComputerName)"
  grep -vE "^[0-9:]+ scenario " "$LOG" || echo "no output"
else
  echo "M1 two-Mac · role $role · $(scutil --get ComputerName)"
  grep -E "PASS|FAIL|SHA-256|sheet|merged by itself" "$LOG" || echo "no output"
fi

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
scripts/build-nib.sh "$SIGN"   # and checks the app is newer than every source file
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
  rm -f "$LOGS/$name.log"   # a launch that never gets going must say so, not show an earlier run's log
  "$APP" -NibScenario "$name" -NibScenarioLog "$PWD/$LOGS/$name.log" "$@" >/dev/null 2>&1 &
  local pid=$!
  # The guard's output goes nowhere, or its sleep would hold a pipe open for 120 s. A hung
  # scenario is sampled first (build/scenarios/<name>-sample.txt), to show where it waits.
  rm -f "$LOGS/$name-sample.txt"
  ( sleep 115; kill -0 "$pid" 2>/dev/null && sample "$pid" 3 -file "$PWD/$LOGS/$name-sample.txt"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 & local guard=$!
  disown "$guard"
  wait "$pid" 2>/dev/null || true
  pkill -P "$guard" sleep 2>/dev/null || true; kill "$guard" 2>/dev/null || true   # (a launch that dies at once leaves no sleep yet)
  echo "==> $name"
  grep -E "PASS|FAIL|after the last" "$LOGS/$name.log" || echo "FAIL no output$([[ -f $LOGS/$name-sample.txt ]] && echo " (hung: sampled in $LOGS/$name-sample.txt)")"
}

# A clean start for the scenarios' own journal (a failed earlier run can leave a snapshot that
# raises a conflict at launch). A scenario's Nib keeps its journal, History, lists and settings
# apart from the Nib in daily use (Application Support/nib-scenarios, com.banastas.nib.scenarios),
# so this never touches the user's.
rm -f "$HOME/Library/Application Support/nib-scenarios/Journal/"*.json

marker="crash-$(date +%s)"
run type
run clipboard
run cleantext
run lines
run find
run carets
run minimap
run mdlist       # a numbered list typed in a 2.4 MB Markdown file: its colors, and the lines drawn again
run widescroll -NibWideScrollBig YES   # a scroll to a stretch taller than the view, then typing, in 2.4 MB (TextKit 2 crashed)
run palette
run gutter
run tidy
run menubar
# Another app holding a global shortcut, for the first run's warning (SC2).
swiftc -O -o build/hotkey-holder scripts/hotkey-holder.swift 2>/dev/null || true
run firstrun -NibFakeLoginItem YES -NibHotKeyHolder "$PWD/build/hotkey-holder"
# The `nib` command-line tool (AP4), against the running scenario (it never starts or fronts Nib).
(cd NibKit && swift build --product nib-cli 2>&1 | grep -E "error" || true)
run cli -NibCLI "$PWD/NibKit/.build/debug/nib-cli"
run fileops
run access
run full
run receipts
run undo
run crash -NibMarker "$marker" -NibSaveIdle 600 -NibSaveMax 600
run recover -NibMarker "$marker"
run crash-blocks -NibMarker "$marker" -NibSaveIdle 600 -NibSaveMax 600
run recover-blocks -NibMarker "$marker"
run crash-big -NibMarker "$marker" -NibSaveIdle 600 -NibSaveMax 600   # a 2.4 MB buffer's journal: an edit log
run recover-big -NibMarker "$marker"
run external -NibSaveIdle 600 -NibSaveMax 600
run unsent -NibHoldUploads YES
run merge
cp "$LOGS/merge.log" "$LOGS/merge-note-first.log"
run merge -NibNoteTiming never
cp "$LOGS/merge.log" "$LOGS/merge-no-note.log"
run merge -NibNoteTiming late
cp "$LOGS/merge.log" "$LOGS/merge-late-note.log"
run merge -NibNoteTiming after
run mergeview
run duplicates
run conflictversions
hmarker="history-$(date +%s)"
run history -NibMarker "$hmarker" -NibSlowQuit YES   # its quit cut off by the 10 s watchdog, as when iCloud is slow
run history-closed -NibMarker "$hmarker"   # the save it quit with went into History all the same
run files
run syntax
run themes
run synclog
run holdretry -NibFailPauses 2 -NibFailPausesFor hold-
cp "$LOGS/holdretry.log" "$LOGS/holdretry-4099.log"
run holdretry -NibUnsupportedPauses 1 -NibFailPausesFor hold-
run handback
run handback-return -NibFailResumes 1
run refusal -NibLoseHold YES
cp "$LOGS/refusal.log" "$LOGS/refusal-lost-hold.log"
run refusal
umarker="untitled-$(date +%s)"
run untitled -NibMarker "$umarker" -NibSaveIdle 600 -NibSaveMax 600
run untitled-return -NibMarker "$umarker"
run untitled-quit -NibMarker "$umarker"
run refresh
run large
# Near the end: renaming folders, and moving files to the Trash and deleting them, in iCloud
# Drive leaves its daemons busy for a minute or more ("Resource busy" for every pause in the
# `merge` after them, 2026-09-30).
run moved -NibSaveIdle 600 -NibSaveMax 600
run deleted -NibSaveIdle 600 -NibSaveMax 600
run icloudoff
run evicted
# Last: making, uploading and deleting a 2.4 MB file leaves iCloud's daemons on this Mac slow to
# answer for minutes (PRD §8), which the launches after it would wait on.
run bigfile

echo "==> Paused files left behind: $(cat "$HOME/Library/Application Support/nib-scenarios/paused.json" 2>/dev/null || echo none)"
failed=0
for name in type clipboard cleantext lines find carets minimap mdlist widescroll palette gutter tidy menubar firstrun cli fileops access moved deleted full icloudoff evicted receipts undo crash recover crash-blocks recover-blocks crash-big recover-big external unsent merge-note-first merge-no-note merge-late-note merge mergeview duplicates conflictversions history history-closed files syntax themes synclog holdretry-4099 holdretry handback handback-return refusal-lost-hold refusal untitled untitled-return untitled-quit refresh large bigfile; do   # this run's logs only
  [[ -f $LOGS/$name.log ]] || failed=1   # a launch that never got going wrote nothing
  grep -q "FAIL" "$LOGS/$name.log" 2>/dev/null && failed=1
done
if (( failed )); then echo "SOME CHECKS FAILED"; exit 1; fi
echo "ALL CHECKS PASSED"

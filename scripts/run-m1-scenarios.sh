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
APP=build/DerivedData/Build/Products/Debug/Rune.app/Contents/MacOS/Rune
# Waits for iCloud to finish uploading the test file before each launch (`run`, below).
swiftc -O -o build/wait-uploaded scripts/wait-uploaded.swift 2>/dev/null || true

# A fresh test file (generated text): earlier runs leave conflict blocks in it, and the
# banner and the scenarios would see them all.
if [[ $SIGN == adhoc ]]; then TESTFILE="$HOME/Library/Mobile Documents/com~apple~CloudDocs/nib-spike/scratch-test.md"
else TESTFILE="$HOME/Library/Mobile Documents/iCloud~com~banastas~nib/Documents/Test/scratch-test.md"; fi
mkdir -p "$(dirname "$TESTFILE")"
printf 'Rune test file: generated text for the scenarios, started afresh by run-m1-scenarios.sh at %s.\n' "$(date '+%Y-%m-%d %H:%M:%S')" > "$TESTFILE"
LOGS=build/scenarios
mkdir -p "$LOGS"

run() {   # [AS=<log name>] run <name> [args…]: one scenario, killed after 120 s if it hangs
  local name=$1; shift
  # A variant (AS=merge-no-note run merge …) has a log and a sample of its own: the next run of
  # the same scenario deleted a hung variant's sample (`merge`, 2026-10-02).
  local file=${AS:-$name}
  rm -f "$LOGS/$file.log"   # a launch that never gets going must say so, not show an earlier run's log
  # Not while iCloud is still uploading the test file (a run before handed it back with an upload
  # to make, or this script just wrote it), up to 2 minutes: Nib doesn't pause a file mid-upload
  # (PRD §4.3), so a launch then opens it unheld and waits on iCloud (`merge` with no note at
  # 18:04 on 2026-10-02: 100 s, then killed).
  local waited=""
  [[ -x build/wait-uploaded ]] && waited=$(build/wait-uploaded "$TESTFILE" 120 || true)
  "$APP" -NibScenario "$name" -NibScenarioLog "$PWD/$LOGS/$file.log" "$@" >/dev/null 2>&1 &
  local pid=$!
  # The guard's output goes nowhere, or its sleep would hold a pipe open for 120 s. A hung
  # scenario is sampled first (build/scenarios/<log name>-sample.txt), to show where it waits.
  rm -f "$LOGS/$file-sample.txt"
  ( sleep 115; kill -0 "$pid" 2>/dev/null && sample "$pid" 3 -file "$PWD/$LOGS/$file-sample.txt"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 & local guard=$!
  disown "$guard"
  wait "$pid" 2>/dev/null || true
  pkill -P "$guard" sleep 2>/dev/null || true; kill "$guard" 2>/dev/null || true   # (a launch that dies at once leaves no sleep yet)
  echo "==> $file"
  if [[ -n $waited ]]; then echo "$waited"; fi
  grep -E "PASS|FAIL|STALL|after the last" "$LOGS/$file.log" || echo "FAIL no output$([[ -f $LOGS/$file-sample.txt ]] && echo " (hung: sampled in $LOGS/$file-sample.txt)")"
}

# A clean start for the scenarios' own journal (a failed earlier run can leave a snapshot that
# raises a conflict at launch). A scenario's Nib keeps its journal, History, lists and settings
# apart from the Nib in daily use (Application Support/nib-scenarios, com.banastas.nib.scenarios),
# so this never touches the user's.
rm -f "$HOME/Library/Application Support/nib-scenarios/Journal/"*.json

marker="crash-$(date +%s)"
run type
run uploads   # 30 s of typing: uploads every 20 s, then 3 s after it stops (§4.3 step 7)
run clipboard
run cleantext
run lines
run find
run findjump   # Find's jumps through 223 KB, by the keyboard too: AppKit's crash at a scroll (2026-10-04)
run carets
run minimap
run nap   # 40 s out of sight, not napped
run mdlist       # a numbered list typed in a 2.4 MB Markdown file: its colors, and the lines drawn again
run widescroll -NibWideScrollBig YES   # a scroll to a stretch taller than the view, then typing, in 2.4 MB (TextKit 2 crashed)
run palette
run headings     # Go to Heading (⌘R): a Markdown file's headings, the jump, 2.4 MB off the main thread
run pairs        # ED10: closing pairs as typed, matching brackets and tags, indent guides, each off in Settings
run gutter
run tidy
run menubar
# Another app holding a global shortcut, for the first run's warning (SC2).
swiftc -O -o build/hotkey-holder scripts/hotkey-holder.swift 2>/dev/null || true
run firstrun -NibFakeLoginItem YES -NibHotKeyHolder "$PWD/build/hotkey-holder"
run defaultapps   # Settings › Files: Rune as the default app, a kind at a time (a stand-in, never the Mac's)
run synchud   # the sync HUD (§5.3): ⇧⌘Y, Escape, its log, the WARNING panel
run about     # About Rune (§5.10) and its Acknowledgements (DS3)
run dock      # the Dock: the ✕ badge while a conflict is unresolved (AP8), the icon hidden (AP6)
run services  # Services › Append to Rune Scratch and Clean Text, and the Shortcuts (SC8, PT7)
# The `nib` command-line tool (AP4), against the running scenario (it never starts or fronts Nib).
(cd NibKit && swift build --product nib-cli 2>&1 | grep -E "error" || true)
run cli -NibCLI "$PWD/NibKit/.build/debug/nib-cli"
run license -NibLicensing YES -NibCLI "$PWD/NibKit/.build/debug/nib-cli"   # DS4: the trial's lock, in memory (never the Mac's trial)
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
AS=merge-note-first run merge
AS=merge-no-note run merge -NibNoteTiming never
AS=merge-late-note run merge -NibNoteTiming late
AS=merge-quit run merge -NibNoteTiming quit   # closed while it waits for the note: the merge made then, and saved
run merge -NibNoteTiming after
run mergeview
run duplicates
run conflictversions
hmarker="history-$(date +%s)"
run history -NibMarker "$hmarker" -NibSlowQuit YES   # its quit cut off by the 10 s watchdog, as when iCloud is slow
run history-closed -NibMarker "$hmarker"   # the save it quit with went into History all the same
run findhistory   # SY18: Find comes up empty, names the version History has it in, opens it; Copy Paragraph
run files
run syntax
run themes
run synclog
AS=holdretry-4099 run holdretry -NibFailPauses 2 -NibFailPausesFor hold-
run holdretry -NibUnsupportedPauses 1 -NibFailPausesFor hold-
run handback
run handback-return -NibFailResumes 1
AS=refusal-lost-hold run refusal -NibLoseHold YES
run refusal
umarker="untitled-$(date +%s)"
run untitled -NibMarker "$umarker" -NibSaveIdle 600 -NibSaveMax 600
run untitled-return -NibMarker "$umarker"
run untitled-quit -NibMarker "$umarker"
rmarker="reopen-$(date +%s)"
run reopen -NibMarker "$rmarker" -NibReopenFiles YES          # files open at a quit…
run reopen-return -NibMarker "$rmarker" -NibReopenFiles YES   # …open again at the next launch, in their order
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
for name in type uploads clipboard cleantext lines find findjump carets minimap nap mdlist widescroll palette headings pairs gutter tidy menubar firstrun cli fileops access moved deleted full icloudoff evicted receipts undo crash recover crash-blocks recover-blocks crash-big recover-big external unsent merge-note-first merge-no-note merge-late-note merge-quit merge mergeview duplicates conflictversions history history-closed files syntax themes synclog holdretry-4099 holdretry handback handback-return refusal-lost-hold refusal untitled untitled-return untitled-quit reopen reopen-return refresh large bigfile; do   # this run's logs only
  [[ -f $LOGS/$name.log ]] || failed=1   # a launch that never got going wrote nothing
  grep -q "FAIL" "$LOGS/$name.log" 2>/dev/null && failed=1
done
if (( failed )); then echo "SOME CHECKS FAILED"; exit 1; fi
echo "ALL CHECKS PASSED"

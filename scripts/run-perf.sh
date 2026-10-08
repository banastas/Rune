#!/usr/bin/env bash
# §6.5, measured (PRD): an optimized build with the scenarios in it (Debug's harness, code
# optimized as a release is: -O Swift, -Os C, so tree-sitter isn't at -O0), in its own folder,
# then the `perf` scenario and ten cold launches. Prints each MEASURED line with its target.
# About five minutes after the build (the first build of this folder takes a few minutes more).
# The scratch file is its own, started afresh in the test folder: small (§6.5's "a small scratch
# file"), or of the size given, generated Markdown (the scratch file's size in daily use, or 2.4 MB).
# Not scratch-test.md, which is whatever a suite or a repro left (420 KB of a merge repro on
# 2026-10-02, and idle memory "with a small scratch file" measured 132 MB). Not beside a suite.
#   scripts/run-perf.sh [bytes]
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
DERIVED=build/DerivedDataPerf
echo "==> Building nib (optimized, with the scenarios)"
xcodebuild -project nib.xcodeproj -scheme nib -configuration Debug -derivedDataPath "$DERIVED" \
  -destination "platform=macOS" -allowProvisioningUpdates \
  SWIFT_OPTIMIZATION_LEVEL=-O GCC_OPTIMIZATION_LEVEL=s ENABLE_DEBUG_DYLIB=NO -quiet build
APP=$DERIVED/Build/Products/Debug/Rune.app/Contents/MacOS/Rune
LOGS=build/scenarios
mkdir -p "$LOGS"
SIZE=${1:-0}
SUFFIX=optimized${1:+-$1}
FOLDER="$HOME/Library/Mobile Documents/iCloud~com~banastas~nib/Documents/Test"
SCRATCH=perf-scratch.md
mkdir -p "$FOLDER"
# As the `idlebig` scenario makes it: a heading every 50 lines, a list item every third.
awk -v n="$SIZE" 'BEGIN {
  line = "Rune perf scratch file: generated text, started afresh by run-perf.sh.\n"; printf "%s", line; total = length(line)
  while (total < n) {
    m++
    if (m % 50 == 0) line = "## Notes for " m "\n"
    else if (m % 3 == 0) line = "- item " m " with `code` and **bold** text\n"
    else line = "Line " m ": see https://example.com/" m " and the config.json file.\n"
    printf "%s", line; total += length(line)
  }
}' > "$FOLDER/$SCRATCH"
echo "==> the scratch file: $SCRATCH, $(wc -c < "$FOLDER/$SCRATCH" | tr -d ' ') bytes"

run() {   # run <name> <log> [limit]: one launch, killed after the limit (120 s)
  local name=$1 log=$2 limit=${3:-120}
  rm -f "$log"
  "$APP" -NibScenario "$name" -NibScenarioLog "$PWD/$log" -NibScenarioScratch "$SCRATCH" >/dev/null 2>&1 &
  local pid=$!
  ( sleep "$limit"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 & local guard=$!
  disown "$guard"
  wait "$pid" 2>/dev/null || true
  pkill -P "$guard" sleep 2>/dev/null || true; kill "$guard" 2>/dev/null || true
}

echo "==> perf"
run perf "$LOGS/perf-$SUFFIX.log" 300   # its idle measures wait for Rune to go quiet first
grep -E "MEASURED|FAIL|PASS" "$LOGS/perf-$SUFFIX.log" || echo "FAIL no output"

echo "==> ten cold launches"
times=()
for i in $(seq 1 10); do
  run launch "$LOGS/launch-$SUFFIX-$i.log"
  t=$(grep -oE "editable [0-9]+ ms after launch" "$LOGS/launch-$SUFFIX-$i.log" | grep -oE "[0-9]+" || true)
  grep -oE "editable .*" "$LOGS/launch-$SUFFIX-$i.log" | sed 's/^/    /' || true
  [[ -n $t ]] && times+=("$t")
  sleep 2
done
if (( ${#times[@]} )); then
  sorted=$(printf '%s\n' "${times[@]}" | sort -n | tr '\n' ' ')
  echo "MEASURED cold launch to an editable scratch window: ${sorted}ms · target ≤ 300 ms p95"
else
  echo "FAIL no launch times"
fi
# Each launch handed it back to iCloud as it quit: gone, with its note.
rm -f "$FOLDER/$SCRATCH" "$FOLDER/.nib/latest-$SCRATCH.json"

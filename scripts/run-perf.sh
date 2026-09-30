#!/usr/bin/env bash
# §6.5, measured (PRD): an optimized build with the scenarios in it (Debug's harness, code
# optimized as a release is: -O Swift, -Os C, so tree-sitter isn't at -O0), in its own folder,
# then the `perf` scenario and ten cold launches. Prints each MEASURED line with its target.
# About five minutes after the build (the first build of this folder takes a few minutes more).
#   scripts/run-perf.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
DERIVED=build/DerivedDataPerf
echo "==> Building nib (optimized, with the scenarios)"
xcodebuild -project nib.xcodeproj -scheme nib -configuration Debug -derivedDataPath "$DERIVED" \
  -destination "platform=macOS" -allowProvisioningUpdates \
  SWIFT_OPTIMIZATION_LEVEL=-O GCC_OPTIMIZATION_LEVEL=s ENABLE_DEBUG_DYLIB=NO -quiet build
APP=$DERIVED/Build/Products/Debug/Nib.app/Contents/MacOS/Nib
LOGS=build/scenarios
mkdir -p "$LOGS"

run() {   # run <name> <log> [limit]: one launch, killed after the limit (120 s)
  local name=$1 log=$2 limit=${3:-120}
  rm -f "$log"
  "$APP" -NibScenario "$name" -NibScenarioLog "$PWD/$log" >/dev/null 2>&1 &
  local pid=$!
  ( sleep "$limit"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 & local guard=$!
  disown "$guard"
  wait "$pid" 2>/dev/null || true
  pkill -P "$guard" sleep 2>/dev/null || true; kill "$guard" 2>/dev/null || true
}

echo "==> perf"
run perf "$LOGS/perf-optimized.log" 300   # its idle measures wait for Nib to go quiet first
grep -E "MEASURED|FAIL|PASS" "$LOGS/perf-optimized.log" || echo "FAIL no output"

echo "==> ten cold launches"
times=()
for i in $(seq 1 10); do
  run launch "$LOGS/launch-$i.log"
  t=$(grep -oE "editable [0-9]+ ms after launch" "$LOGS/launch-$i.log" | grep -oE "[0-9]+" || true)
  grep -oE "editable .*" "$LOGS/launch-$i.log" | sed 's/^/    /' || true
  [[ -n $t ]] && times+=("$t")
  sleep 2
done
if (( ${#times[@]} )); then
  sorted=$(printf '%s\n' "${times[@]}" | sort -n | tr '\n' ' ')
  echo "MEASURED cold launch to an editable scratch window: ${sorted}ms · target ≤ 300 ms p95"
else
  echo "FAIL no launch times"
fi

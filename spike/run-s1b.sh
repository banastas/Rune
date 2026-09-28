#!/usr/bin/env bash
# M0 · S1b on two Macs (PRD "M0 results"). Run the same line on both Macs with the same
# start time (24-hour HH:MM, at least a minute ahead), Mac A first or second, no matter:
#
#   Mac A:  spike/run-s1b.sh a 23:10
#   Mac B:  spike/run-s1b.sh b 23:10
#
# Takes about 11 minutes after the start time (part2, the last three tests only: about 4). Everything happens in iCloud Drive/nib-spike/
# on generated files. Mac B also runs the M1 single-Mac checks at the end. Paste the summary
# printed at the end (also in spike/results/s1b-<role>-summary.txt).
set -euo pipefail
cd "$(dirname "$0")"
role=${1:?usage: run-s1b.sh a|b HH:MM [all|part2]}
at=${2:?usage: run-s1b.sh a|b HH:MM [all|part2]}
plan=${3:-all}   # part2: only the paused-file, conflict and attribute tests (about 4 minutes)
[[ $role == a || $role == b ]] || { echo "role is a or b"; exit 2; }
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

T0=$(date -j -f "%H:%M:%S" "$at:00" +%s)
now=$(date +%s)
(( T0 > now + 45 )) || { echo "start time $at is less than a minute away (or past): pick a later one"; exit 2; }
tag=$(date -r "$T0" +%m%d-%H%M)
host=$(scutil --get ComputerName)

echo "==> Building the probe on $host"
swift build -c release -q
scripts/bundle.sh >/dev/null
B=.build/NibSpike.app/Contents/MacOS/nib-spike
mkdir -p results
out=results/s1b-$role
rm -f "$out"-p[0-9]-*.txt "$out"-xattr-*.txt "$out"-summary.txt   # this run's files only

wait_until() { local t=$((T0 + $1)) n; n=$(date +%s); (( t > n )) && sleep $((t - n)); return 0; }
phase() {   # phase <seconds after start> <name> <mode and options…>
  local offset=$1 name=$2; shift 2
  wait_until "$offset"
  echo "==> [$(date +%H:%M:%S)] $name"
  "$B" "$@" > "$out-$name.txt" 2>&1 || true
  grep RESULT "$out-$name.txt" || echo "   (no RESULT line; see $out-$name.txt)"
}

echo "==> Role $role on $host; plan $plan; starting at $at (in $(( T0 - $(date +%s) )) s). Leave both Macs awake and online."
if [[ $plan == part2 && $role == a ]]; then
  phase 0   xattr-write   xattr-write --file "xattr-$tag.md"
  phase 10  p5-push       writer --file "p5-$tag.md" --every 10 --count 7 --mode push
  phase 110 p6-race       race --role first --file "race-$tag.md" --at $((T0 + 110))
elif [[ $plan == part2 ]]; then
  phase 10  p5-paused     watch-paused --file "p5-$tag.md" --seconds 60
  phase 110 p6-race       race --role second --file "race-$tag.md" --at $((T0 + 110))
  phase 215 xattr-check   xattr-check --file "xattr-$tag.md"
elif [[ $role == a ]]; then
  phase 0   xattr-write   xattr-write --file "xattr-$tag.md"
  phase 20  p1-plain      writer --file "p1-$tag.md" --every 5 --count 16
  phase 130 p2-plain      writer --file "p2-$tag.md" --every 5 --count 16
  phase 240 p3-push       writer --file "p3-$tag.md" --every 5 --count 16 --mode push
  phase 360 p4-push       writer --file "p4-$tag.md" --every 5 --count 16 --mode push
  phase 480 p5-push       writer --file "p5-$tag.md" --every 10 --count 7 --mode push
  phase 580 p6-race       race --role first --file "race-$tag.md" --at $((T0 + 580))
else
  phase 20  p1-plain      reader --file "p1-$tag.md" --seconds 100
  phase 130 p2-fetch      reader --file "p2-$tag.md" --seconds 100 --fetch-every 5
  phase 240 p3-push       reader --file "p3-$tag.md" --seconds 110
  phase 360 p4-push-fetch reader --file "p4-$tag.md" --seconds 110 --fetch-every 5
  phase 480 p5-paused     watch-paused --file "p5-$tag.md" --seconds 60
  phase 580 p6-race       race --role second --file "race-$tag.md" --at $((T0 + 580))
  phase 690 xattr-check   xattr-check --file "xattr-$tag.md"
fi
"$B" cleanup >/dev/null 2>&1 || true

{
  echo "S1b role $role · $host · $(sw_vers -productVersion) · start $at"
  grep -h RESULT "$out"-p[0-9]-*.txt "$out"-xattr-*.txt 2>/dev/null | sed 's/^[0-9:.]* //'
} > "$out-summary.txt"

if [[ $role == b && $plan == all ]]; then
  echo "==> M1 single-Mac checks on $host"
  ../scripts/run-m1-scenarios.sh 2>&1 | grep -E "FAIL|ALL CHECKS|SOME CHECKS|Test run" | tee -a "$out-summary.txt" || true
fi
echo
echo "================ paste this ================"
cat "$out-summary.txt"

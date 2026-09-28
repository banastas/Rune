#!/usr/bin/env bash
# M0 · S1 on one Mac: every single-Mac mode, output in results/. Takes about four minutes.
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
swift build -c release -q
scripts/bundle.sh >/dev/null
B=.build/NibSpike.app/Contents/MacOS/nib-spike
mkdir -p results
host=$(scutil --get ComputerName | tr ' ’' '__')
run() { local name=$1; shift; echo "==> $name"; "$B" "$@" | tee "results/s1-$host-$name.txt" | grep RESULT || true; }
run upload-200k     upload --size 200k
run typing-200k     typing --size 200k --every 1 --count 15
run push-200k       push-typing --size 200k --every 1 --count 20 --upload-every 3
run push-2.4m       push-typing --size 2.4m --every 1 --count 12 --upload-every 3
run controls-inplace controls --size 200k --write inplace
run controls-replace controls --size 200k --write replace
run evict-200k      evict --size 200k
run presenter-20k   presenter --size 20k
run metadata        metadata
"$B" cleanup | grep RESULT

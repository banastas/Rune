#!/usr/bin/env bash
# The fidelity harness (PRD HL7, S3): Sublime's rendering of the reference files with
# An Old Hope · Nib, dumped to sublime/, then Nib's comparison against it.
#
#   fidelity/run.sh          # dump with Sublime (it opens a window of its own), then compare
#   fidelity/run.sh compare  # compare against the last dump only
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

if [[ ${1:-} != compare ]]; then
  USER_PKG="$HOME/Library/Application Support/Sublime Text/Packages/User"
  SUBL="/Applications/Sublime Text.app/Contents/SharedSupport/bin/subl"
  [[ -x $SUBL && -d $USER_PKG ]] || { echo "Sublime Text isn't installed where expected" >&2; exit 1; }
  cp NibFidelity.py "$USER_PKG/NibFidelity.py"
  cp ../themes/an-old-hope-nib.tmTheme "$USER_PKG/an-old-hope-nib.tmTheme"
  OUT="$PWD/sublime"
  rm -rf "$OUT"; mkdir -p "$OUT"
  FILES=$(python3 -c 'import json, os, sys; print(json.dumps([os.path.abspath(p) for p in sorted(sys.argv[1:])]))' reference/*)
  ask() { "$SUBL" --background --command "nib_fidelity_dump {\"files\": $FILES, \"out\": \"$OUT\"}"; }
  ask
  # A Sublime that was just launched may not have loaded the plugin yet: ask again.
  for i in $(seq 1 60); do
    [[ -f $OUT/done ]] && break
    (( i == 8 )) && ask
    sleep 1
  done
  [[ -f $OUT/done ]] || { echo "no dump from Sublime after 60 s" >&2; exit 1; }
  echo "==> Sublime dumped $(ls "$OUT"/*.json | wc -l | tr -d ' ') files"
fi

if [[ -d ../NibKit/Sources/NibFidelity ]]; then
  (cd ../NibKit && swift run -c release nib-fidelity ../fidelity 2>&1 | grep -v '^\[' )
fi

#!/usr/bin/env bash
# Installs the `rune` command-line tool (PRD AP4; `nib` until 2026-10-07): builds it (release) and
# copies it into a folder on your PATH, ~/.local/bin unless you name another. It asks the running
# Rune for everything, by its bundle ID, so it works with whichever copy macOS knows. An old `nib`
# there is left alone: it still reaches Rune (the same bundle ID), so nothing set to it breaks.
#   scripts/install-nib-cli.sh [folder]
# For git and $EDITOR:  export EDITOR="rune -w"
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
DEST=${1:-$HOME/.local/bin}
(cd NibKit && swift build -c release --product nib-cli 2>&1 | tail -1)
mkdir -p "$DEST"
install -m 755 NibKit/.build/release/nib-cli "$DEST/rune"   # the product is nib-cli (a scheme named nib would clash with the app's)
echo "Installed $DEST/rune"
case ":$PATH:" in *":$DEST:"*) ;; *) echo "($DEST isn't on your PATH yet)";; esac
if [[ -e "$DEST/nib" ]]; then
  echo "The old $DEST/nib is still there and still works. Once EDITOR and anything else uses rune, remove it: rm \"$DEST/nib\""
fi

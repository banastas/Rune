#!/usr/bin/env bash
# Installs the `nib` command-line tool (PRD AP4): builds it (release) and copies it into a
# folder on your PATH, ~/.local/bin unless you name another. It asks the running Nib for
# everything, so it works with whichever Nib.app macOS knows (the Debug build, until there's
# a release).
#   scripts/install-nib-cli.sh [folder]
# For git and $EDITOR:  export EDITOR="nib -w"
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
DEST=${1:-$HOME/.local/bin}
(cd NibKit && swift build -c release --product nib 2>&1 | tail -1)
mkdir -p "$DEST"
install -m 755 NibKit/.build/release/nib "$DEST/nib"
echo "Installed $DEST/nib"
case ":$PATH:" in *":$DEST:"*) ;; *) echo "($DEST isn't on your PATH yet)";; esac

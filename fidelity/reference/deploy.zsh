#!/usr/bin/env zsh
# Deploy the vendor review site, then tell the team.
set -euo pipefail

readonly HOST="me@seedbox"
readonly DEST="~/www"
typeset -a FILES=(dist/*.html dist/*.css)
local count=0

log() {
  print -P "%F{cyan}[$(date +%H:%M:%S)]%f $*"
}

check_disk() {
  local free
  free=$(ssh "$HOST" "df -h ${DEST} | awk 'NR==2 {print \$4}'")
  if [[ -z "$free" ]]; then
    log "couldn't read free space" >&2
    return 1
  fi
  echo "$free"
}

for file in "${FILES[@]}"; do
  if [[ -f $file && ! -L $file ]]; then
    (( count += 1 ))
  fi
done

case "${1:-deploy}" in
  deploy)
    log "deploying $count files ($(check_disk) free)"
    rsync -av --delete ./dist/ "$HOST:$DEST/" || exit 2
    ;;
  dry-run|-n)
    rsync -avn ./dist/ "$HOST:$DEST/"
    ;;
  *)
    echo "usage: ${0:t} [deploy|dry-run]" >&2
    exit 64
    ;;
esac

cat <<NOTE | mail -s "Deployed" team@example.com
Deployed ${count} files to ${HOST} at $(date).
NOTE

export LAST_DEPLOY="$(date +%s)"
unset count

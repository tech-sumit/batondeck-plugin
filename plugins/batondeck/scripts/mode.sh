#!/usr/bin/env bash
# BatonDeck plugin — arm/disarm this session's autonomous mode flag. While a mode is armed, the
# plugin's Stop hook refuses to let the session go idle and steers the model back into its loop.
#
#   mode.sh worker|master ["note echoed back on resume — put project/board/agent here"]
#   mode.sh off
set -euo pipefail
dir="${BATONDECK_STATE_DIR:-$HOME/.batondeck}"; mkdir -p "${dir}"
sid="${BATONDECK_SESSION_ID:-default}"
f="${dir}/mode-${sid}"
case "${1:?usage: mode.sh worker|master|off [note]}" in
  worker|master)
    printf '%s\n%s\n' "$1" "${2:-}" > "${f}"
    echo "mode=$1 armed (${f}) — /batondeck:off to disarm"
    ;;
  off)
    rm -f "${f}"
    echo "mode off"
    ;;
  *)
    echo "usage: mode.sh worker|master|off [note]" >&2; exit 2
    ;;
esac

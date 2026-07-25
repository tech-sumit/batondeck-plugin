#!/usr/bin/env bash
# BatonDeck plugin — session lifecycle.
#   start: export BATONDECK_SESSION_ID into the session env so scripts/mode.sh keys its flag per session.
#   end:   disarm any mode flag so a dead session can't leave the stop gate armed.
set -euo pipefail
input="$(cat || true)"
sid="$(printf '%s' "${input}" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("session_id",""))
except Exception: print("")')"
dir="${BATONDECK_STATE_DIR:-$HOME/.batondeck}"
case "${1:-}" in
  start)
    if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -n "${sid}" ]; then
      printf 'export BATONDECK_SESSION_ID=%q\n' "${sid}" >> "${CLAUDE_ENV_FILE}"
    fi
    ;;
  end)
    [ -n "${sid}" ] && rm -f "${dir}/mode-${sid}"
    # ponytail: also clear the no-session-id fallback flag; two env-less concurrent sessions would share it anyway
    rm -f "${dir}/mode-default"
    ;;
esac

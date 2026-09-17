#!/usr/bin/env bash
# BatonDeck plugin — arm/disarm this session's autonomous mode flag. While a mode is armed, the
# plugin's Stop hook refuses to let the session go idle and steers the model back into its loop.
#
#   mode.sh worker|master ["note echoed back on resume — put project/board/agent here"]
#   mode.sh off
set -euo pipefail
dir="${BATONDECK_STATE_DIR:-$HOME/.batondeck}"; mkdir -p "${dir}"
# Shared derivation — this wrote `mode-default` while stop-gate.sh read `mode-<sid>`.
BD_SID_HINT=""   # no payload here; must not inherit a stale hint
. "$(cd "$(dirname "$0")" && pwd)/session-id.sh"
sid="${BD_SID}"
f="${dir}/mode-${sid}"
case "${1:?usage: mode.sh worker|master|off [note]}" in
  worker|master)
    printf '%s\n%s\n' "$1" "${2:-}" > "${f}"
    echo "mode=$1 armed (${f}) — /batondeck:off to disarm"
    # SAY SO WHEN THE SESSION ID WAS GUESSED. This script gets no hook payload, so with
    # BATONDECK_SESSION_ID absent it resolves through the shared pin — and with two sessions in one
    # state dir that pin can name the OTHER one. Measured: session A ran `mode.sh worker` and armed
    # `mode-B`; A's own gate then read `mode-A`, found nothing and let the turn end. A silently
    # unarmed, B armed without asking. The flag file is printed above, so the operator can see which
    # session was armed; this line tells them the value was not authoritative.
    if [ "${BD_SID_SRC:-}" = "pin" ]; then
      echo "warning: session id '${sid}' came from the shared pin, not this session's environment." >&2
      echo "         If another BatonDeck session is live in the same state dir, this may have armed" >&2
      echo "         THAT session. Give each session its own BATONDECK_STATE_DIR to make this exact." >&2
    fi
    ;;
  off)
    rm -f "${f}"
    echo "mode off"
    ;;
  *)
    echo "usage: mode.sh worker|master|off [note]" >&2; exit 2
    ;;
esac

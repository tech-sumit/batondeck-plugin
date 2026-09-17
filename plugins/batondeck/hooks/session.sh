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
    # PIN the payload session id unconditionally, not only when $CLAUDE_ENV_FILE exists. That export
    # was the ONLY way other processes learned this value, so with the var absent the listener and
    # the waiter picked different filenames and the session slept forever.
    #
    # SOURCED IN `start` ONLY, and the placement is load-bearing. Sourcing it above the case ran the
    # pin-writer on `end` too, so a teardown RE-PINNED to its own sid before clearing it — which made
    # the "only delete our own pin" guard below always true and deleted a concurrent session's pin
    # anyway. The snippet's value (BD_SID) is never read here; the pin is the whole point of the call.
    BD_SID_HINT="${sid}"
    # shellcheck source=/dev/null
    . "$(cd "$(dirname "$0")/../scripts" && pwd)/session-id.sh"
    if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -n "${sid}" ]; then
      printf 'export BATONDECK_SESSION_ID=%q\n' "${sid}" >> "${CLAUDE_ENV_FILE}"
    fi
    ;;
  end)
    [ -n "${sid}" ] && rm -f "${dir}/mode-${sid}"
    # ponytail: KNOWN CEILING — also clear the no-session-id fallback flag. Two env-less concurrent
    # sessions share that flag, so one ending disarms the other. Accepted: env-less sessions are the
    # rare fallback. Upgrade path: key the fallback on PPID if concurrent env-less sessions turn up.
    rm -f "${dir}/mode-default"
    # The session-id pin is per-SESSION state and must not outlive the session: a stale one was
    # inherited by every env-less caller in the NEXT session (see plugin/scripts/session-id.sh).
    # ONLY when it is OURS. An unconditional `rm` here deletes a concurrent session's pin and sends
    # its env-less callers to the $PPID fallback — cleaning up after yourself must not mean cleaning
    # up after someone else. An empty payload sid means we never pinned anything, so leave it alone.
    if [ -n "${sid}" ] && [ "$(cat "${dir}/session-id" 2>/dev/null)" = "${sid}" ]; then
      rm -f "${dir}/session-id"
    fi
    ;;
esac

#!/usr/bin/env bash
# THE ONLY session-id derivation. SOURCE this; do not execute it.
#
#   BD_SID_HINT="<payload sid or empty>"; . "$(dirname "$0")/session-id.sh"   -> sets BD_SID
#
# THE HINT IS A VARIABLE, NOT "$1", and that is not a style choice. `.` without arguments leaves the
# SOURCING script's positional parameters visible, so reading "$1" here made `mode.sh on` resolve its
# session id to "on". Caught by check 10g on its first run.
#
# WHY IT EXISTS. Six sites derived a session id independently and disagreed:
#   hooks/session.sh      payload, exported ONLY if $CLAUDE_ENV_FILE is set
#   scripts/wake-start.sh payload, else ${BATONDECK_SESSION_ID:-${AGENT_PID:-$PPID}}
#   hooks/stop-gate.sh    payload, else ${BATONDECK_SESSION_ID:-default}
#   scripts/mode.sh       ${BATONDECK_SESSION_ID:-default}
#   scripts/listener-start.sh  ${AGENT_PID:-$PPID}          <- ignored both others
#   skill/scripts/wake-wait.mjs  BATONDECK_SESSION_ID || 'default'
#
# With CLAUDE_ENV_FILE unset — the ordinary case — the listener wrote its deliveries to
# `<state>/wake/<payload-sid>.jsonl` while the waiter watched `<state>/wake/default.jsonl`. The stop
# gate then saw a live `wake-wait-default-*.pid` and PERMITTED the idle, so the session slept forever
# on the only delivery path there is. The same split made `mode.sh` write `mode-default` while
# `stop-gate.sh` read `mode-<sid>` and exited 0 — an armed shift that silently was not armed.
#
# A SHARED CHAIN IS NOT ENOUGH, which is the subtle part. The hooks receive the session id in their
# payload; a Bash tool running `wake-wait.mjs` does not, and no chain of env vars can invent it. So the
# first caller with a DEFINITIVE source (payload, or an explicit BATONDECK_SESSION_ID) PINS it, and
# later callers with no better source read the pin back. Same first-writer-wins shape the derived agent
# NAME uses, and keyed per state dir — so BATONDECK_STATE_DIR isolates concurrent sessions, which is
# exactly what skill/SKILL.md tells people to use it for.

# MEASURED LIMIT — CONCURRENT SESSIONS SHARING ONE STATE DIR. Two sessions in one dir make the pin
# flap, and the flap is not benign: with A and B both live, A running `mode.sh worker` (no payload)
# resolved through the pin to B and armed `mode-B`, so A's own gate then read `mode-A`, found nothing
# and exited 0 — A unarmed, B armed without asking. First-writer-wins was not better, it just made
# exactly one session wrong deterministically instead of both intermittently. There is no pin shape
# that fixes this, because the losing caller has no definitive source to prefer.
# Two things follow, and both are implemented rather than documented:
#   - the DELIVERY path does not use the pin at all — stop-gate.sh hands the model its payload sid
#     explicitly, so the forever-sleep cannot be reached this way (hooks/stop-gate.sh).
#   - a caller that fell back to the pin can SEE that it did, via BD_SID_SRC, and say so.
# The supported way to run concurrent sessions is one BATONDECK_STATE_DIR each, as skill/SKILL.md says.

# shellcheck disable=SC2034  # BD_SID / BD_SID_SRC are consumed by the sourcing script
_bd_sid_state="${BATONDECK_STATE_DIR:-${HOME:-/tmp}/.batondeck}"
_bd_sid_pin="${_bd_sid_state}/session-id"
_bd_sid_arg="${BD_SID_HINT:-}"

# Definitive sources, in order: an explicit payload-derived value, then the environment.
# BD_SID_SRC says WHICH, because a caller needs to distinguish a value it can trust from one it
# guessed off shared state: `pin` is only correct while one session owns the state dir.
BD_SID=""; BD_SID_SRC=""
case "${_bd_sid_arg}" in ''|'-') ;; *) BD_SID="${_bd_sid_arg}"; BD_SID_SRC="payload" ;; esac
if [ -z "${BD_SID}" ] && [ -n "${BATONDECK_SESSION_ID:-}" ]; then
  BD_SID="${BATONDECK_SESSION_ID}"; BD_SID_SRC="env"
fi

if [ -n "${BD_SID}" ]; then
  # *** RE-PIN WHENEVER THE DEFINITIVE VALUE DISAGREES. FIRST-WRITER-WINS WAS WRONG HERE. ***
  # This originally kept the first value forever, by analogy with the derived agent NAME pin. The
  # analogy is false and the difference is the whole bug: a worktree path is stable ACROSS sessions, a
  # session id changes EVERY session. Nothing cleared the pin, so from the second session in a state
  # dir every env-less caller inherited session 1's id while payload callers got the real one —
  # `mode.sh` wrote `mode-<old>` while `stop-gate.sh` read `mode-<new>` and exited 0 (an armed shift
  # silently not armed), and `wake-wait.mjs` watched `<old>.jsonl` while the listener wrote
  # `<new>.jsonl` (the forever-sleep). Both are the failure modes this file's header claims to fix,
  # reproduced BY the fix.
  # Within one session every definitive caller carries the SAME payload id, so this writes identical
  # bytes and cannot split a running listener's filename — the case the old guard was protecting.
  # Concurrent sessions sharing ONE state dir still resolve last-definitive-writer-wins; that is a
  # real limit, and strictly better than a permanently stale pin. BATONDECK_STATE_DIR separates them.
  if [ ! -s "${_bd_sid_pin}" ] || [ "$(cat "${_bd_sid_pin}" 2>/dev/null)" != "${BD_SID}" ]; then
    mkdir -p "${_bd_sid_state}" 2>/dev/null || true
    printf '%s' "${BD_SID}" > "${_bd_sid_pin}" 2>/dev/null || true
  fi
else
  # No definitive source: read the pin, then fall back. Sanitized on read — it becomes a FILENAME.
  if [ -s "${_bd_sid_pin}" ]; then
    BD_SID="$(LC_ALL=C tr -d '\000-\037' < "${_bd_sid_pin}" 2>/dev/null | LC_ALL=C sed 's|[^A-Za-z0-9._-]|-|g' | LC_ALL=C cut -c1-64)" || BD_SID=""
    [ -z "${BD_SID}" ] || BD_SID_SRC="pin"
  fi
  if [ -z "${BD_SID}" ]; then BD_SID="${AGENT_PID:-$PPID}"; BD_SID_SRC="ppid"; fi
  if [ -z "${BD_SID}" ]; then BD_SID="default"; BD_SID_SRC="default"; fi
fi
# BD_SID_HINT is consumed, not left lying around for the next sourcing site to inherit.
unset _bd_sid_state _bd_sid_pin _bd_sid_arg BD_SID_HINT   # BD_SID / BD_SID_SRC are the outputs

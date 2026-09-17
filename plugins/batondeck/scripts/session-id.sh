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

# shellcheck disable=SC2034  # BD_SID is consumed by the sourcing script
_bd_sid_state="${BATONDECK_STATE_DIR:-${HOME:-/tmp}/.batondeck}"
_bd_sid_pin="${_bd_sid_state}/session-id"
_bd_sid_arg="${BD_SID_HINT:-}"

# Definitive sources, in order: an explicit payload-derived value, then the environment.
BD_SID=""
case "${_bd_sid_arg}" in ''|'-') ;; *) BD_SID="${_bd_sid_arg}" ;; esac
[ -n "${BD_SID}" ] || BD_SID="${BATONDECK_SESSION_ID:-}"

if [ -n "${BD_SID}" ]; then
  # Pin it for callers that cannot know it. First writer wins: re-pinning mid-session would split the
  # delivery filename from the one an already-running listener is writing to.
  if [ ! -s "${_bd_sid_pin}" ]; then
    mkdir -p "${_bd_sid_state}" 2>/dev/null || true
    printf '%s' "${BD_SID}" > "${_bd_sid_pin}" 2>/dev/null || true
  fi
else
  # No definitive source: read the pin, then fall back. Sanitized on read — it becomes a FILENAME.
  if [ -s "${_bd_sid_pin}" ]; then
    BD_SID="$(LC_ALL=C tr -d '\000-\037' < "${_bd_sid_pin}" 2>/dev/null | LC_ALL=C sed 's|[^A-Za-z0-9._-]|-|g' | LC_ALL=C cut -c1-64)" || BD_SID=""
  fi
  [ -n "${BD_SID}" ] || BD_SID="${AGENT_PID:-$PPID}"
  [ -n "${BD_SID}" ] || BD_SID="default"
fi
# BD_SID_HINT is consumed, not left lying around for the next sourcing site to inherit.
unset _bd_sid_state _bd_sid_pin _bd_sid_arg BD_SID_HINT

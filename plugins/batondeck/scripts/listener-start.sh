#!/usr/bin/env bash
# Start the BatonDeck assigned-task listener for THIS Claude Code session, tied to the session's
# lifetime. Meant to be called by the plugin's SessionStart hook (paired with listener-stop.sh on
# SessionEnd). It NEVER breaks the session: if the listener isn't configured or is opted out, it just
# no-ops and exits 0. Idempotent — re-running for the same session does nothing.
#
# Config (env wins, else KEY=value lines in ${BATONDECK_CONFIG:-$HOME/.batondeck/config}):
#   BATONDECK_TASK_LISTENER   off|0|false|no|disabled disables it (unset/anything else = enabled).
#                             In the FILE either spelling is accepted: `BATONDECK_TASK_LISTENER=off`
#                             or the shorter `TASK_LISTENER=off` (worker-assigned.sh takes the same pair).
#   BATONDECK_PROJECT, BATONDECK_BOARD, ASSIGNEE, AGENT_CMD   required to actually start (else it stays idle)
# File values keep their interior spaces — `AGENT_CMD=claude -p "work the task"` and
# `ASSIGNEE=Claude Worker 1` are the documented shapes, so only surrounding whitespace and ONE matched
# layer of surrounding quotes are stripped.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cfg="${BATONDECK_CONFIG:-$HOME/.batondeck/config}"

# Last KEY=value line for KEY in the config file, verbatim.
cfg_get() { [ -f "$cfg" ] && sed -n "s/^[[:space:]]*$1[[:space:]]*=//p" "$cfg" | tail -n1; }
# Trim surrounding whitespace, then one PAIRED layer of surrounding quotes. Never touches the interior.
trim() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  case "$v" in \"*\"|\'*\') v="${v:1:${#v}-2}";; esac
  printf '%s' "$v"
}
# get KEY → env override (verbatim), else the trimmed config-file value.
get() {
  local v="${!1:-}"
  if [ -n "$v" ]; then printf '%s' "$v"; return; fi
  trim "$(cfg_get "$1")"
}
norm() { printf '%s' "$1" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]'; }

# Opt-out: env wins, then either file spelling. (Read the file keys directly — `get TASK_LISTENER`
# would pick up an unrelated $TASK_LISTENER from the environment.)
pref="${BATONDECK_TASK_LISTENER:-}"
[ -n "$pref" ] || pref="$(cfg_get BATONDECK_TASK_LISTENER)"
[ -n "$pref" ] || pref="$(cfg_get TASK_LISTENER)"
case "$(norm "$pref")" in off|0|false|no|disabled) exit 0;; esac

PROJECT="$(get BATONDECK_PROJECT)"; BOARD="$(get BATONDECK_BOARD)"
NAME="$(get ASSIGNEE)"; CMD="$(get AGENT_CMD)"
# Opt-in: only run when fully configured. Missing config = stay idle (no noise, no error).
[ -n "$PROJECT" ] && [ -n "$BOARD" ] && [ -n "$NAME" ] && [ -n "$CMD" ] || exit 0

SID="${AGENT_PID:-$PPID}"   # tie to the session (a hook's parent is the Claude Code process)
state="${BATONDECK_STATE_DIR:-${TMPDIR:-/tmp}/batondeck}"; mkdir -p "$state" 2>/dev/null || true
pidf="$state/listener-$SID.pid"

# Idempotent: a listener already running for this session? do nothing.
if [ -f "$pidf" ] && kill -0 "$(cat "$pidf" 2>/dev/null)" 2>/dev/null; then exit 0; fi

BATONDECK_PROJECT="$PROJECT" BATONDECK_BOARD="$BOARD" ASSIGNEE="$NAME" AGENT_CMD="$CMD" AGENT_PID="$SID" \
  nohup "$here/worker-assigned.sh" >"$state/listener-$SID.log" 2>&1 &
echo $! > "$pidf"
echo "[batondeck] task listener started for ${NAME} (pid $!, session $SID) — log: $state/listener-$SID.log" >&2
exit 0

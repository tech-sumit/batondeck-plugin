#!/usr/bin/env bash
# Stop the BatonDeck assigned-task listener for THIS session. Called by the plugin's SessionEnd hook;
# the reliable backstop to the worker's own agent-PID watchdog. Always exits 0.
set -uo pipefail
SID="${AGENT_PID:-$PPID}"
state="${BATONDECK_STATE_DIR:-${TMPDIR:-/tmp}/batondeck}"
pidf="$state/listener-$SID.pid"
[ -f "$pidf" ] || exit 0
pid="$(cat "$pidf" 2>/dev/null || true)"
[ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || true
rm -f "$pidf" 2>/dev/null || true
exit 0

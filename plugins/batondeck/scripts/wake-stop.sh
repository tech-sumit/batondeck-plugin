#!/usr/bin/env bash
# Stop THIS session's wake listener (SessionEnd hook). Always exits 0.
set -uo pipefail
input="$(cat || true)"
sid="$(printf '%s' "${input}" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("session_id",""))
except Exception: print("")' 2>/dev/null || true)"
[ -n "$sid" ] || sid="${BATONDECK_SESSION_ID:-${AGENT_PID:-$PPID}}"
state="${BATONDECK_STATE_DIR:-${TMPDIR:-/tmp}/batondeck}"
pidf="$state/wake-$sid.pid"
[ -f "$pidf" ] || exit 0
pid="$(cat "$pidf" 2>/dev/null || true)"
[ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || true
rm -f "$pidf" 2>/dev/null || true
exit 0

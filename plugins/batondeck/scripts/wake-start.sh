#!/usr/bin/env bash
# Start THIS session's wake listener (SessionStart hook). Unlike listener-start.sh next door, it is NOT
# gated on worker config — every connected session gets a doorbell, which is the whole finding of T-585.
# Never breaks a session: no node, no sign-in, no wake channel -> it says so and exits 0.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
input="$(cat || true)"
sid="$(printf '%s' "${input}" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("session_id",""))
except Exception: print("")' 2>/dev/null || true)"
[ -n "$sid" ] || sid="${BATONDECK_SESSION_ID:-${AGENT_PID:-$PPID}}"

command -v node >/dev/null 2>&1 || { echo "[batondeck] wake listener needs node; skipping" >&2; exit 0; }
[ -f "$here/wake-listener.cjs" ] || { echo "[batondeck] wake-listener.cjs missing from this install; skipping" >&2; exit 0; }

state="${BATONDECK_STATE_DIR:-${TMPDIR:-/tmp}/batondeck}"; mkdir -p "$state" 2>/dev/null || true
pidf="$state/wake-$sid.pid"
# Idempotent: one listener per session, however many times SessionStart fires.
if [ -f "$pidf" ] && kill -0 "$(cat "$pidf" 2>/dev/null)" 2>/dev/null; then exit 0; fi

BATONDECK_SESSION_ID="$sid" nohup node "$here/wake-listener.cjs" >"$state/wake-$sid.log" 2>&1 &
echo $! > "$pidf"
exit 0

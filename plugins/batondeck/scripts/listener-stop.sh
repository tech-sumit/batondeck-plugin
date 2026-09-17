#!/usr/bin/env bash
# Stop the BatonDeck assigned-task listener for THIS session. Called by the plugin's SessionEnd hook;
# the reliable backstop to the worker's own agent-PID watchdog. Always exits 0.
set -uo pipefail
# *** THE SAME DERIVATION AS listener-start.sh, OR THIS HOOK STOPS NOTHING. *** The pidfile is named
# `listener-<SID>.pid` by start; if stop computes a different SID the file is never found, `[ -f ]`
# exits 0 "successfully", and the listener leaks past SessionEnd with only its own agent-PID watchdog
# left to reap it. This line read `${AGENT_PID:-$PPID}` while start had already moved to the session-id
# snippet — a guaranteed mismatch, and a regression introduced by migrating one side of a pair.
# Sourced DEFENSIVELY and before any early exit, so a packaging gap cannot kill a SessionEnd hook
# whose own contract is "always exits 0": `set -u` on ${BD_SID} after a failed source is the C3 death
# shape. session-id.sh ships via `cp -R plugin/scripts` (scripts/build-plugin.sh:66) and is present in
# 2.0.1, so this is belt-and-braces — but the cost is one guard and the failure is a broken session end.
BD_SID_HINT=""   # SessionEnd gives this script no payload on stdin; must not inherit a stale hint
BD_SID=""
_bd_snip="$(cd "$(dirname "$0")" && pwd)/session-id.sh"
# shellcheck source=/dev/null
[ -r "${_bd_snip}" ] && . "${_bd_snip}"
SID="${BD_SID:-${AGENT_PID:-$PPID}}"
state="${BATONDECK_STATE_DIR:-${TMPDIR:-/tmp}/batondeck}"
pidf="$state/listener-$SID.pid"
[ -f "$pidf" ] || exit 0
pid="$(cat "$pidf" 2>/dev/null || true)"
[ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || true
rm -f "$pidf" 2>/dev/null || true
exit 0

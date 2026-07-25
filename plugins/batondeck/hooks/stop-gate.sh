#!/usr/bin/env bash
# BatonDeck plugin — Stop gate. While worker/master mode is armed for this session:
#   - a LIVE background watch (watch.sh pidfile) means the session may go idle — the harness will
#     wake it when the watch exits with work. Zero-token idle: allow the stop.
#   - no live watch means the loop is broken — block turn-end and steer the model back into it.
# Scope, deliberately narrow: this fires ONLY for a session the user explicitly put on shift via
# /batondeck:worker or /batondeck:master, only while that session's own mode flag exists, and it never
# blocks twice in a row (stop_hook_active circuit breaker below). Disarm any time with /batondeck:off
# (scripts/mode.sh off). It steers the armed loop; it must never override what the user asked for.
set -euo pipefail
input="$(cat || true)"
# Read BOTH session_id and stop_hook_active from the one hook payload.
read -r sid hook_active <<EOF
$(printf '%s' "${input}" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
print(d.get("session_id","") or "-", "1" if d.get("stop_hook_active") else "0")')
EOF
[ "${sid}" = "-" ] && sid="${BATONDECK_SESSION_ID:-default}"
dir="${BATONDECK_STATE_DIR:-$HOME/.batondeck}"
# Use ONLY this session's own flag. No fallback to mode-default — that let a flag armed under the
# 'default' key (BATONDECK_SESSION_ID unset) conscript unrelated sessions into a loop they never chose.
f="${dir}/mode-${sid}"
[ -f "${f}" ] || exit 0

mode="$(sed -n 1p "${f}")"
note="$(sed -n 2p "${f}")"

# A live background watch (any of this session's, keyed per-PID) is the session's ear — idle is safe.
for pidf in "${dir}"/watch-"${sid}"-*.pid; do
  [ -e "${pidf}" ] || continue
  if kill -0 "$(cat "${pidf}" 2>/dev/null)" 2>/dev/null; then exit 0; fi
done

# Circuit breaker: if we ALREADY blocked this turn-cycle (stop_hook_active) and there's still no live
# watch, the loop can't self-heal (e.g. auth failing) — allow the stop instead of re-blocking forever.
[ "${hook_active}" = "1" ] && exit 0

if [ "${mode}" = "worker" ]; then
  reason="BatonDeck WORKER mode is on${note:+ (${note})} but no watch is running. Restart the wait: run the batondeck-worker skill's scripts/watch.sh work '<wait_for_task args>' as a BACKGROUND Bash task (run_in_background), then end your turn - the harness wakes you when it exits with a task. On a task: claim it, read its modelHint, and dispatch the ticket to a subagent on that model/effort (work it per the skill: context -> follow-ups -> work -> heartbeat -> complete with deliverable), then restart the background watch and end your turn. If the loop errors repeatedly (auth/network), run mode.sh off, report the error, and stop. Go off shift with /batondeck:off."
elif [ "${mode}" = "master" ]; then
  reason="BatonDeck MASTER mode is on${note:+ (${note})} but no watch is running. Restart the wait: run the batondeck-worker skill's scripts/watch.sh events '{\"projectId\":...,\"boardId\":...}' as a BACKGROUND Bash task (run_in_background), then end your turn - the harness wakes you when board events land. On events: REVIEW -> judge deliverable (move to DONE or add_follow_up reopen:true with change requests); BLOCKED -> resolve or reassign; DEAD_LETTER -> fix brief + requeue_task; stalled -> reap_stale_leases, consider working a leaf yourself. When the goal is fully DONE, summarize and run mode.sh off. Go off shift with /batondeck:off."
else
  exit 0
fi

REASON="${reason}" python3 -c 'import json,os; print(json.dumps({"decision":"block","reason":os.environ["REASON"]}))'

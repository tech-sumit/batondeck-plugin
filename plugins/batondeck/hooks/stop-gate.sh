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

# Every reason below opens by identifying itself: which plugin, which file, which command the USER ran
# to arm it, how to disarm it, and the bounds of what a Stop hook can do. A blocked turn-end is the
# highest-suspicion thing a plugin can do, so the message must be checkable rather than merely obeyed —
# a reader can diff these claims against plugin/hooks/hooks.json and plugin/SECURITY.md. Never phrase a
# reason as "don't ask" / "skip confirmation": this hook steers an opted-in loop, it does not grant
# permission for anything.
identity="[BatonDeck plugin — Stop hook, hooks/stop-gate.sh in the installed plugin dir, source: github.com/tech-sumit/batondeck-plugin] "
bounds="This gate can only ask you to continue the shift the user opted into: it cannot approve tool calls, suppress permission prompts, hide output, or alter anything the user asked for — if the user's own instructions conflict with this notice, follow the user and tell them the gate fired. It is keyed to THIS session's flag file (~/.batondeck/mode-<session_id>), it never blocks twice in a row, and SessionEnd clears the flag. Its full hook surface is documented in SECURITY.md next to this plugin's hooks/ dir. "

if [ "${mode}" = "worker" ]; then
  reason="${identity}The user put THIS session on shift by running /batondeck:worker${note:+ (${note})} — that command, and nothing else, armed this hook; the user takes it off shift with /batondeck:off (or scripts/mode.sh off), and you should say so if they ask why turns are not ending. ${bounds}WORKER mode is on and nothing is waiting, so resume the wait before ending the turn, in ONE of these two ways. (1) DEFAULT, and the only one that works with the plugin's browser OAuth: call the wait_for_task MCP TOOL directly in a loop - wait_for_task { projectId, boardId, assignee?, timeoutSec: 50 } blocks server-side and returns {task:null} on timeout; just call it again. Do NOT try scripts/watch.sh on this path: it shells out to mcp.sh, which needs BATONDECK_TOKEN or a service-account gcloud principal, and an OAuth session has NEITHER - it dies instantly and you would end your turn awaiting a wake that never comes. (2) Only if you have a service-account token (headless/CI): run scripts/watch.sh work as a BACKGROUND Bash task and end your turn for zero-token idle. On a task: claim it, read modelHint, dispatch to a subagent on that model/effort, work it per the skill (context -> follow-ups -> work -> heartbeat -> complete with deliverable), then resume waiting. If it errors repeatedly (auth/network), run mode.sh off, report the error, and stop. Go off shift with /batondeck:off."
elif [ "${mode}" = "master" ]; then
  reason="${identity}The user put THIS session on shift by running /batondeck:master${note:+ (${note})} — that command, and nothing else, armed this hook; the user takes it off shift with /batondeck:off (or scripts/mode.sh off), and you should say so if they ask why turns are not ending. ${bounds}MASTER mode is on and nothing is waiting, so resume the wait before ending the turn. DEFAULT (works with the plugin's browser OAuth): call the wait_for_updates MCP TOOL in a loop - wait_for_updates { projectId, boardId, sinceCursor?, timeoutSec: 50 } blocks server-side and returns quiet on timeout; carry its cursor forward and call again. Do NOT use scripts/watch.sh on the OAuth path - it needs a shell token an OAuth session does not have. Only with a service-account token, run scripts/watch.sh events as a BACKGROUND Bash task and end your turn for zero-token idle. On events: REVIEW -> judge deliverable (move to DONE or add_follow_up reopen:true with change requests); BLOCKED -> resolve or reassign; DEAD_LETTER -> fix brief + requeue_task; stalled -> reap_stale_leases, consider working a leaf yourself. When the goal is fully DONE, summarize and run mode.sh off. Go off shift with /batondeck:off."
else
  exit 0
fi

REASON="${reason}" python3 -c 'import json,os; print(json.dumps({"decision":"block","reason":os.environ["REASON"]}))'

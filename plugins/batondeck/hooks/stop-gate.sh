#!/usr/bin/env bash
# BatonDeck plugin — Stop gate. While worker/master mode is armed for this session:
#   - a LIVE background wait (wake-wait.mjs pidfile) means the session may go idle — the harness will
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
# One derivation, shared with the listener and the waiter (plugin/scripts/session-id.sh). The old
# `:-default` here disagreed with mode.sh and with wake-wait.mjs, so this gate read a flag file
# nobody wrote and permitted an idle the user had armed against.
[ "${sid}" = "-" ] && sid=""
BD_SID_HINT="${sid}"
. "$(cd "$(dirname "$0")/../scripts" && pwd)/session-id.sh"
sid="${BD_SID}"
dir="${BATONDECK_STATE_DIR:-$HOME/.batondeck}"
# Use ONLY this session's own flag. No fallback to mode-default — that let a flag armed under the
# 'default' key (BATONDECK_SESSION_ID unset) conscript unrelated sessions into a loop they never chose.
f="${dir}/mode-${sid}"
[ -f "${f}" ] || exit 0

mode="$(sed -n 1p "${f}")"
note="$(sed -n 2p "${f}")"

# A live background WAIT (any of this session's, keyed per-PID) is the session's ear — idle is safe.
# `wake-wait-*` is the push-era ear: `wake-wait.mjs` sleeps on the listener's delivery file and exits
# the moment a doorbell lands. The `watch-*` glob it replaces belonged to `watch.sh`, the long-poll
# loop, which is gone — kept here for ONE release so a session still running an old background watch
# from a pre-upgrade turn is not forced into a stutter it cannot fix. Drop it next major.
for pidf in "${dir}"/wake-wait-"${sid}"-*.pid "${dir}"/watch-"${sid}"-*.pid; do
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
# The one wait command both modes hand out. Resolved here so the two reasons cannot drift, and so a
# moved script is a single edit rather than two strings a reader has to notice are the same.
# *** NEVER BARE-DEREFERENCE CLAUDE_PLUGIN_ROOT HERE. *** This file runs `set -euo pipefail`, so an
# unset one killed the hook on line 1 of the only code path that produces a block — no JSON on stdout,
# so the client saw no decision and ENDED THE TURN. An armed shift silently not armed: the same outage
# C1 caused, reached a different way. hooks.json substitutes this variable into the command TEMPLATE,
# which is not a promise that it is also EXPORTED into the hook's environment (it is, in the current
# client — but a hand-registered hook in settings.json is not, and neither is a client that only
# substitutes). The hook's own location is the authority: it lives at <plugin-root>/hooks/stop-gate.sh.
_bd_root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}"
wake_wait="${_bd_root}/skills/batondeck-worker/scripts/wake-wait.mjs"
# *** THE DELIVERY PATH CARRIES ITS SESSION ID EXPLICITLY, SO IT NEVER READS THE PIN. ***
# wake-wait.mjs is run by the MODEL, from a Bash tool, with no hook payload — so it used to resolve
# its delivery filename through the shared pin. This hook HAS the payload sid, so handing it over is
# the whole fix: two sessions sharing one state dir make that pin flap (measured — see the limit note
# in scripts/session-id.sh), and a waiter that resolves the wrong sid watches a file nothing writes
# and sleeps forever. That is the most expensive failure in this system, and this line is what makes
# it unreachable by that route.
wait_cmd="BATONDECK_SESSION_ID=${sid} node \"${wake_wait}\" 3500"
identity="[BatonDeck plugin — Stop hook, hooks/stop-gate.sh in the installed plugin dir, source: github.com/tech-sumit/batondeck-plugin] "
headless="This works on the browser sign-in AND on a headless BATONDECK_TOKEN (T-594): the listener reads either. A bd_ CLI token is the one shape that cannot drive it — those are opaque, so they reach neither the MCP endpoint nor the doorbell; use an MCP access token or an org API key instead. "
bounds="This gate can only ask you to continue the shift the user opted into: it cannot approve tool calls, suppress permission prompts, hide output, or alter anything the user asked for — if the user's own instructions conflict with this notice, follow the user and tell them the gate fired. It is keyed to THIS session's flag file (~/.batondeck/mode-<session_id>), it never blocks twice in a row, and SessionEnd clears the flag. Its full hook surface is documented in SECURITY.md next to this plugin's hooks/ dir. "

if [ "${mode}" = "worker" ]; then
  reason="${identity}The user put THIS session on shift by running /batondeck:worker${note:+ (${note})} — that command, and nothing else, armed this hook; the user takes it off shift with /batondeck:off (or scripts/mode.sh off), and you should say so if they ask why turns are not ending. ${bounds}${headless}WORKER mode is on and nothing is waiting, so resume the wait before ending the turn. On the plugin's browser OAuth — this session — the way to wait is: run \`${wait_cmd}\` as a BACKGROUND Bash task and end your turn. Your session's wake listener is already running (SessionStart started it); that command sleeps on its delivery file and exits the moment a doorbell lands, which is what wakes you — zero tokens while idle. On waking, read the event: 'doorbell' means work is waiting, so call claim_next { projectId, boardId, assignee: YOUR agent name } FIRST — and your name is DERIVED, not chosen: read it with \`bash \"\$(dirname \"${wake_wait}\")/../../scripts/agent-id.sh\" --name \"\$CLAUDE_PROJECT_DIR\"\` rather than guessing, because a guessed name matches no session row and the doorbell resolves BY name and only then the bare claim_next { projectId, boardId } — the doorbell is contentless, so a directed wake and a frontier broadcast are indistinguishable, and the bare call claims from the top 8 by score, which on a busy board need not contain the ticket routed to you. Either way it selects and claims in one op and returns \`resume\`; READ resume BEFORE YOU TOUCH GIT, because non-null means a previous agent already worked this lane (check out resume.branch and continue from resume.lastCheckpoint.NEXT rather than resetting). Work it per the skill (context -> follow-ups -> work -> heartbeat -> complete with a deliverable), then arm the wait again. 'signin-required' means the sign-in expired: tell the user to run npx -y mcp-remote https://mcp.batondeck.com/mcp, then run mode.sh off. 'unavailable' or repeated 'detached' means the channel is down, not your credentials: report it and run mode.sh off. Go off shift with /batondeck:off."
elif [ "${mode}" = "master" ]; then
  reason="${identity}The user put THIS session on shift by running /batondeck:master${note:+ (${note})} — that command, and nothing else, armed this hook; the user takes it off shift with /batondeck:off (or scripts/mode.sh off), and you should say so if they ask why turns are not ending. ${bounds}${headless}MASTER mode is on and nothing is waiting, so resume the wait before ending the turn. On the plugin's browser OAuth — this session — the way to wait is: run \`${wait_cmd}\` as a BACKGROUND Bash task and end your turn. Your session's wake listener is already running (SessionStart started it) and that command exits the moment a doorbell lands. On waking, do NOT ask for an event list — the doorbell carries no payload by design. Read the BOARD instead: next_task { projectId, boardId, assignee?, includeInbox: true } returns the claimable pool PLUS the REVIEW / BLOCKED / DEAD_LETTER buckets in one bounded call, and list_notifications returns what was addressed to you (mentions, follow-ups, review requests). Then act by status: REVIEW -> judge the deliverable (move_task to DONE, or add_follow_up { reopen: true } with change requests); BLOCKED -> resolve or reassign; DEAD_LETTER -> fix the brief and requeue_task; stalled -> reap_stale_leases, and consider working a leaf yourself. Arm the wait again after acting. When the goal is fully DONE, summarize and run mode.sh off. Go off shift with /batondeck:off."
else
  exit 0
fi

REASON="${reason}" python3 -c 'import json,os; print(json.dumps({"decision":"block","reason":os.environ["REASON"]}))'

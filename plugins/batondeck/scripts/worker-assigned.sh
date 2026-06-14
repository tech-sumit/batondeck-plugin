#!/usr/bin/env bash
# batondeck-worker skill — a single NAMED worker, bound to a running agent's lifetime.
#
# It long-polls for tasks the board ROUTED to this agent (task.assignee == ASSIGNEE), claims each, and
# hands it to AGENT_CMD. Unlike worker.sh (which drains a finite board then exits), it stays up waiting
# for *future* assignments — but ONLY while the agent is alive:
#   • it refuses to start if the agent isn't running, and
#   • it exits when the agent process goes away — a watchdog tears it down within ~WATCH_SECS, and it
#     also exits on SIGTERM (e.g. a SessionEnd hook).
# Mid-task caveat: if the agent dies while a task is IN FLIGHT, the worker lets that AGENT_CMD finish
# (the lease belongs to the task, not the agent) and exits right after — it never abandons work midway.
#
# Requires on PATH: bash, python3, mktemp, curl, gcloud (the last two via mcp.sh).
#
# Env (required): BATONDECK_PROJECT, BATONDECK_BOARD
#   ASSIGNEE   this agent's name — MUST equal the name the board assigns (the display name a human picks
#              in the task drawer's Assignee field). A mismatch means assignments silently never arrive.
#   AGENT_CMD  invoked per task as:  AGENT_CMD <taskId> <leaseId>   (the thing that actually does the work)
# Env (optional):
#   AGENT_PID  the (same-user) process whose lifetime bounds this worker (default: the parent, $PPID). The
#              worker dies when it exits. Launching from a short-lived Claude Code SessionStart hook? Pass
#              the *session* PID explicitly — $PPID would be the hook, which exits at once.
#   WAIT_SECS  long-poll window, clamped to 1..50 (default 20).   WATCH_SECS  agent-liveness poll (default 2).
#   plus the connection env from mcp.sh (BATONDECK_TOKEN or BATONDECK_AGENT_SA, BATONDECK_CORE_URL).
#
# Assignment is advisory — an assigned task is still claimable by anyone, so we claim promptly and wait
# for the next if we lose the race. (PID reuse is a theoretical risk for very short-lived agents.)
set -uo pipefail
cd "$(dirname "$0")"

# ── Opt-out switch ────────────────────────────────────────────────────────────────────────────────
# The task listener is opt-outable. It does NOT run when disabled via either:
#   • env:  BATONDECK_TASK_LISTENER=off            (off | 0 | false | no | disabled)
#   • file: TASK_LISTENER=off  in  ${BATONDECK_CONFIG:-$HOME/.batondeck/config}
# Unset / any other value = enabled. (A SessionStart hook that auto-launches this should make the same
# check so it doesn't even spawn — see SKILL.md.) Checked first, so opting out needs no other env.
listener_pref="${BATONDECK_TASK_LISTENER:-}"
if [ -z "$listener_pref" ]; then
  _cfg="${BATONDECK_CONFIG:-$HOME/.batondeck/config}"
  [ -f "$_cfg" ] && listener_pref="$(sed -n 's/^[[:space:]]*TASK_LISTENER[[:space:]]*=//p' "$_cfg" | tail -n1)"
fi
listener_pref="$(printf '%s' "$listener_pref" | tr -d $'"\'' | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
case "$listener_pref" in
  off|0|false|no|disabled)
    echo "[worker] task listener disabled (set BATONDECK_TASK_LISTENER=on to enable) — not starting." >&2
    exit 0;;
esac

: "${BATONDECK_PROJECT:?set BATONDECK_PROJECT to the project id P-...}"
: "${BATONDECK_BOARD:?set BATONDECK_BOARD to the board id B-...}"
: "${ASSIGNEE:?set ASSIGNEE to this agent name; it must equal the name the board assigns}"
: "${AGENT_CMD:?set AGENT_CMD to the command run per task as AGENT_CMD taskId leaseId}"
AGENT_PID="${AGENT_PID:-$PPID}"
WATCH_SECS="${WATCH_SECS:-2}"

# Clamp WAIT_SECS to the server's accepted range (int 1..50); ignore junk so a bad value can't break
# every request and spin the loop.
WAIT_SECS="${WAIT_SECS:-20}"
case "$WAIT_SECS" in ''|*[!0-9]*) WAIT_SECS=20;; esac
[ "$WAIT_SECS" -lt 1 ]  && WAIT_SECS=1
[ "$WAIT_SECS" -gt 50 ] && WAIT_SECS=50

# Preflight: fail loudly if a required binary is missing (else the worker idles silently forever).
for b in python3 mktemp curl; do
  command -v "$b" >/dev/null 2>&1 || { echo "[worker:$ASSIGNEE] missing required binary: $b" >&2; exit 1; }
done

agent_alive() { kill -0 "$AGENT_PID" 2>/dev/null; }   # assumes a same-user PID (kill -0 EPERMs cross-user)

if ! agent_alive; then
  echo "[worker:$ASSIGNEE] no agent running (PID ${AGENT_PID}) — nothing to attend; not starting." >&2
  exit 1
fi

# Build JSON args with python3 (never string interpolation) so quotes/specials in a name or id can't
# corrupt or inject the request. The wait args are static; recompute claim args per task.
WF_ARGS="$(BATONDECK_PROJECT="$BATONDECK_PROJECT" BATONDECK_BOARD="$BATONDECK_BOARD" ASSIGNEE="$ASSIGNEE" WAIT_SECS="$WAIT_SECS" \
  python3 -c 'import json,os;print(json.dumps({"projectId":os.environ["BATONDECK_PROJECT"],"boardId":os.environ["BATONDECK_BOARD"],"assignee":os.environ["ASSIGNEE"],"timeoutSec":int(os.environ["WAIT_SECS"])}))')"

POLL=""; OUT=""; ERR=""; WATCH=""
shutdown() {
  trap - TERM INT EXIT
  if [ -n "$POLL" ]; then pkill -P "$POLL" 2>/dev/null; { kill "$POLL" && wait "$POLL"; } 2>/dev/null; fi   # reap mcp.sh + its curl, quietly
  if [ -n "$WATCH" ]; then pkill -P "$WATCH" 2>/dev/null; kill "$WATCH" 2>/dev/null; fi                     # reap the watchdog + its sleep
  [ -n "$OUT" ] && rm -f "$OUT" 2>/dev/null
  [ -n "$ERR" ] && rm -f "$ERR" 2>/dev/null
  return 0
}
trap 'shutdown; echo "[worker:$ASSIGNEE] stopping." >&2; exit 0' TERM INT
trap 'shutdown' EXIT

# Watchdog: the moment the agent goes away, nudge the main process so it tears down at the next poll
# boundary (an in-flight AGENT_CMD finishes first; see the mid-task caveat above). $$ is this script's
# PID even from inside the subshell.
( while agent_alive; do sleep "$WATCH_SECS"; done; kill -TERM "$$" 2>/dev/null ) &
WATCH=$!

echo "[worker:$ASSIGNEE] up — bound to agent PID ${AGENT_PID}; waiting for work routed to ${ASSIGNEE} on ${BATONDECK_BOARD}." >&2
fails=0
while agent_alive; do
  OUT="$(mktemp)"; ERR="$(mktemp)"
  ./mcp.sh wait_for_task "$WF_ARGS" >"$OUT" 2>"$ERR" &
  POLL=$!
  wait "$POLL"; rc=$?   # interruptible: the TERM trap fires here on agent-stop / SessionEnd
  POLL=""
  if ! agent_alive; then rm -f "$OUT" "$ERR"; OUT=""; ERR=""; break; fi   # agent died during the wait
  if [ "$rc" -ne 0 ]; then
    # The poll itself failed (bad/expired token, 5xx, session error) — back off so a persistent problem
    # can't hot-spin or flood the core, and surface the cause periodically (stderr is otherwise hidden).
    fails=$((fails + 1))
    [ $((fails % 5)) -eq 1 ] && echo "[worker:$ASSIGNEE] poll failed (rc=$rc); backing off ${WATCH_SECS}s. last: $(tail -n1 "$ERR" 2>/dev/null)" >&2
    rm -f "$OUT" "$ERR"; OUT=""; ERR=""
    sleep "$WATCH_SECS"
    continue
  fi
  fails=0
  task="$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));t=d.get("task");print(t["id"] if t else "")' "$OUT" 2>/dev/null || true)"
  rm -f "$OUT" "$ERR"; OUT=""; ERR=""
  [ -z "$task" ] && continue          # clean long-poll timeout — nothing assigned right now; poll again
  agent_alive || break                # re-check just before claiming (shrink the agent-died TOCTOU window)
  CL_ARGS="$(BATONDECK_PROJECT="$BATONDECK_PROJECT" TASK="$task" \
    python3 -c 'import json,os;print(json.dumps({"projectId":os.environ["BATONDECK_PROJECT"],"taskId":os.environ["TASK"]}))')"
  lease="$(./mcp.sh claim_task "$CL_ARGS" 2>/dev/null \
        | python3 -c 'import json,sys;print(json.load(sys.stdin).get("leaseId",""))' 2>/dev/null || true)"
  if [ -z "$lease" ]; then
    echo "[worker:$ASSIGNEE] $task already taken; assignment is advisory — waiting for the next." >&2
    continue
  fi
  echo "[worker:$ASSIGNEE] claimed $task (lease $lease) — handing to AGENT_CMD." >&2
  # Pass taskId/leaseId as positional args ($1/$2), not re-tokenized into the command string.
  bash -c "$AGENT_CMD \"\$1\" \"\$2\"" _ "$task" "$lease" \
    || echo "[worker:$ASSIGNEE] AGENT_CMD failed on $task (lease lazily expires and reopens it)." >&2
done
echo "[worker:$ASSIGNEE] agent stopped — exiting." >&2

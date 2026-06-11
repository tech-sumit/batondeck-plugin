#!/usr/bin/env bash
# conductor-worker skill — one decentralized worker. Loops: next_task (highest-priority READY,
# unblocked, unclaimed) -> claim (the claim is the cross-worker mutex) -> hand the task to AGENT_CMD,
# which does the work and completes/blocks/hands it off per the skill. The board's dependency tree
# gates parallelism automatically; run many of these with fleet.sh for max concurrency.
#
# Env: CONDUCTOR_PROJECT, CONDUCTOR_BOARD (required); AGENT_CMD (required) invoked as:
#        AGENT_CMD <taskId> <leaseId>
#      plus the connection env from mcp.sh (CONDUCTOR_TOKEN or CONDUCTOR_AGENT_SA, CONDUCTOR_CORE_URL).
#      IDLE_SLEEP  seconds between polls when nothing is workable (default 5)
set -euo pipefail
cd "$(dirname "$0")"
: "${CONDUCTOR_PROJECT:?set CONDUCTOR_PROJECT (P-...)}"
: "${CONDUCTOR_BOARD:?set CONDUCTOR_BOARD (B-...)}"
: "${AGENT_CMD:?set AGENT_CMD: command run as: AGENT_CMD <taskId> <leaseId>}"
IDLE_SLEEP="${IDLE_SLEEP:-5}"
WID="${WORKER_ID:-$$}"

remaining_non_terminal() {
  ./mcp.sh list_tasks "{\"projectId\":\"$CONDUCTOR_PROJECT\",\"boardId\":\"$CONDUCTOR_BOARD\",\"limit\":200}" 2>/dev/null \
    | python3 -c "import sys,json;d=json.load(sys.stdin);print(sum(1 for t in d.get('tasks',[]) if t['status'] not in ('DONE','CANCELLED')))" 2>/dev/null || echo 1
}

echo "[worker $WID] starting on $CONDUCTOR_PROJECT/$CONDUCTOR_BOARD"
while :; do
  task=$(./mcp.sh next_task "{\"projectId\":\"$CONDUCTOR_PROJECT\",\"boardId\":\"$CONDUCTOR_BOARD\"}" 2>/dev/null \
        | python3 -c "import sys,json;d=json.load(sys.stdin);t=d.get('task');print(t['id'] if t else '')" 2>/dev/null || true)
  if [ -z "$task" ]; then
    # Nothing workable now: exit if the board is fully drained, else keep polling (blockers in flight
    # will auto-unblock more work).
    if [ "$(remaining_non_terminal)" = "0" ]; then echo "[worker $WID] board drained — exiting"; exit 0; fi
    sleep "$IDLE_SLEEP"; continue
  fi
  lease=$(./mcp.sh claim_task "{\"projectId\":\"$CONDUCTOR_PROJECT\",\"taskId\":\"$task\"}" 2>/dev/null \
        | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('leaseId',''))" 2>/dev/null || true)
  [ -z "$lease" ] && continue   # lost the race (CONFLICT_LOCKED) — grab the next one
  echo "[worker $WID] claimed $task (lease $lease)"
  if bash -c "$AGENT_CMD \"$task\" \"$lease\""; then
    echo "[worker $WID] AGENT_CMD finished $task"
  else
    echo "[worker $WID] AGENT_CMD failed on $task (lease lazily expires and reopens it)"
  fi
done

#!/usr/bin/env bash
# batondeck-worker skill — drain a Conductor board at MAXIMUM concurrency. Launches a fleet of
# persistent workers (worker.sh); each claims the next workable task and runs AGENT_CMD on it. The
# dependency tree gates parallel vs sequential automatically: independent leaves run in parallel,
# dependents wait for their blockers, and completing a task auto-unblocks its dependants — which idle
# workers immediately pick up. Workers exit once the board is fully drained.
#
# Concurrency = min(MAX_AGENTS, current workable frontier). Set MAX_AGENTS >= the frontier's PEAK
# width so workable tasks never wait. Default: auto-size to the current frontier (capped at HARD_CAP).
#
# Env: CONDUCTOR_PROJECT, CONDUCTOR_BOARD, AGENT_CMD (+ mcp.sh connection env).
#      MAX_AGENTS  workers, or "auto" (default auto);  HARD_CAP  ceiling when auto-sizing (default 16)
set -euo pipefail
cd "$(dirname "$0")"
: "${CONDUCTOR_PROJECT:?}"; : "${CONDUCTOR_BOARD:?}"; : "${AGENT_CMD:?}"
MAX_AGENTS="${MAX_AGENTS:-auto}"
HARD_CAP="${HARD_CAP:-16}"

frontier() {
  ./mcp.sh list_tasks "{\"projectId\":\"$CONDUCTOR_PROJECT\",\"boardId\":\"$CONDUCTOR_BOARD\",\"status\":\"READY\",\"limit\":200}" 2>/dev/null \
    | python3 -c "import sys,json,datetime
d=json.load(sys.stdin)
def claimed(t):
  c=t.get('claim')
  return bool(c) and c.get('expiresAt','') > datetime.datetime.now(datetime.timezone.utc).isoformat()
print(sum(1 for t in d.get('tasks',[]) if not t.get('blockedBy') and not claimed(t)))" 2>/dev/null || echo 1
}

if [ "$MAX_AGENTS" = "auto" ]; then
  f=$(frontier); [ "$f" -lt 1 ] && f=1; [ "$f" -gt "$HARD_CAP" ] && f="$HARD_CAP"
  MAX_AGENTS="$f"
  echo "Auto-sized to the current workable frontier: $MAX_AGENTS (cap $HARD_CAP). Raise MAX_AGENTS if the frontier grows."
fi

echo "Launching $MAX_AGENTS workers on $CONDUCTOR_PROJECT/$CONDUCTOR_BOARD ..."
pids=()
for i in $(seq 1 "$MAX_AGENTS"); do
  WORKER_ID="w$i" ./worker.sh &
  pids+=($!)
  sleep 0.2
done
trap 'echo; echo "stopping fleet..."; kill "${pids[@]}" 2>/dev/null || true' INT TERM
wait
echo "Fleet done — board drained."

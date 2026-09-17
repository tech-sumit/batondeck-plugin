#!/usr/bin/env bash
# batondeck-worker skill — drain a BatonDeck board at MAXIMUM concurrency. Launches a fleet of
# persistent workers (worker.sh); each claims the next workable task and runs AGENT_CMD on it. The
# dependency tree gates parallel vs sequential automatically: independent leaves run in parallel,
# dependents wait for their blockers, and completing a task auto-unblocks its dependants — which idle
# workers immediately pick up. Workers exit once the board is fully drained.
#
# Concurrency = min(MAX_AGENTS, current workable frontier). Set MAX_AGENTS >= the frontier's PEAK
# width so workable tasks never wait. Default: auto-size to the current frontier (capped at HARD_CAP).
#
# Env: BATONDECK_PROJECT, BATONDECK_BOARD, AGENT_CMD (+ mcp.sh connection env).
#      MAX_AGENTS  workers, or "auto" (default auto);  HARD_CAP  ceiling when auto-sizing (default 16)
set -euo pipefail
# The checkout the USER launched us from, captured BEFORE the cd below. `mcp.sh` resolves its own
# project dir from ${CLAUDE_PROJECT_DIR:-.}, and after that cd `.` is the plugin INSTALL directory —
# never a linked worktree — so headless (CLAUDE_PROJECT_DIR unset) every lane collapsed onto the legacy
# shared id with no display name. Export both halves explicitly rather than relying on a cwd we change.
BD_LAUNCH_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
cd "$(dirname "$0")"
# Identity resolved from the launch dir (see BD_LAUNCH_DIR above). Blank is never exported: a blank id
# overrides mcp.sh's own resolution, and a blank name makes the core rename the row to 'agent'.
_bd_aid="${BATONDECK_AGENT_ID:-$(bash "$(dirname "$0")/agent-id.sh" "${BD_LAUNCH_DIR}" 2>/dev/null)}"
_bd_nm="${BATONDECK_AGENT:-$(bash "$(dirname "$0")/agent-id.sh" --name "${BD_LAUNCH_DIR}" 2>/dev/null)}"
[ -n "${_bd_aid}" ] && export BATONDECK_AGENT_ID="${_bd_aid}"
[ -n "${_bd_nm}" ]  && export BATONDECK_AGENT="${_bd_nm}"
export CLAUDE_PROJECT_DIR="${BD_LAUNCH_DIR}"
: "${BATONDECK_PROJECT:?}"; : "${BATONDECK_BOARD:?}"; : "${AGENT_CMD:?}"
MAX_AGENTS="${MAX_AGENTS:-auto}"
HARD_CAP="${HARD_CAP:-16}"

frontier() {
  ./mcp.sh list_tasks "{\"projectId\":\"$BATONDECK_PROJECT\",\"boardId\":\"$BATONDECK_BOARD\",\"status\":\"READY\",\"limit\":200}" 2>/dev/null \
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

echo "Launching $MAX_AGENTS workers on $BATONDECK_PROJECT/$BATONDECK_BOARD ..."
pids=()
for i in $(seq 1 "$MAX_AGENTS"); do
  WORKER_ID="w$i" ./worker.sh &
  pids+=($!)
  sleep 0.2
done
trap 'echo; echo "stopping fleet..."; kill "${pids[@]}" 2>/dev/null || true' INT TERM
wait
echo "Fleet done — board drained."

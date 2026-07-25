#!/usr/bin/env bash
# batondeck-worker skill — blocking watch helper: turns the pull-based board into a wait.
# Designed to run as a BACKGROUND task: start it, END YOUR TURN, and the harness wakes you when it
# exits with something to act on — an idle session costs zero turns/tokens. (Foreground with a big
# tool timeout works too.) While a watch runs, the plugin's Stop gate lets the session idle; it
# writes a pidfile the gate checks.
#
#   watch.sh work   '<json-args for wait_for_task>' [max_sec]
#       Worker side. Blocks until a claimable task appears (loops the core's wait_for_task).
#       Prints the {task} JSON → exit 0. Nothing before the deadline → exit 3 (just re-run).
#
#   watch.sh events '{"projectId":"P-…","boardId":"B-…"}' [max_sec]
#       Master side. Blocks until board events land (loops the core's wait_for_updates long-poll —
#       ~0 reads while idle). The cursor persists in the state dir, so re-runs resume where the
#       last one left off. Prints {events:[…],cursor} → exit 0. Quiet → exit 3.
#
#   watch.sh tasks  '{"projectId":"P-…","boardId":"B-…"}' 'T-a,T-b|all' [max_sec] [interval_sec]
#       Fallback for cores without wait_for_updates: poll list_tasks and diff. Blocks until any
#       watched task changes status. Prints {"changed":[…]} → exit 0. Quiet → exit 3.
#
# Defaults: max 3500s for work/events (background-friendly; pass less for foreground), 540s for
# tasks; tasks poll interval 20s. Auth/env: same as mcp.sh.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:?usage: watch.sh work|events|tasks …}"; shift

STATE="${BATONDECK_STATE_DIR:-$HOME/.batondeck}"; mkdir -p "${STATE}" 2>/dev/null || true
SID="${BATONDECK_SESSION_ID:-default}"
# Pidfile is per-PID (…-$$) so two overlapping watches in one session don't share one file — otherwise
# the first to exit would delete the pidfile the second still relies on, and the Stop gate would mis-block.
PIDF="${STATE}/watch-${SID}-$$.pid"
printf '%s' "$$" > "${PIDF}"
trap 'rm -f "${PIDF}"' EXIT
# Long-polls get their own MCP session: on the stateful path, a parked long-poll sharing a session
# with concurrent interactive calls can be left with an unclosed SSE stream.
export MCP_SESSION_SCOPE="watch-$$"

case "${MODE}" in
work)
  ARGS="${1:?usage: watch.sh work '<wait_for_task json-args>' [max_sec]}"
  MAX="${2:-3500}"
  # Spend as much of the wait as possible server-side per call.
  ARGS="$(python3 -c 'import json,sys; a=json.loads(sys.argv[1]); a.setdefault("timeoutSec",50); print(json.dumps(a))' "${ARGS}")"
  start=${SECONDS}
  while (( SECONDS - start < MAX )); do
    out="$("${DIR}/mcp.sh" wait_for_task "${ARGS}")" || { printf '%s\n' "${out}" >&2; exit 1; }
    if printf '%s' "${out}" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("task") else 1)'; then
      printf '%s\n' "${out}"; exit 0
    fi
  done
  echo "watch: no claimable task before the ${MAX}s deadline (re-run to keep waiting)" >&2
  exit 3
  ;;
events)
  SCOPE="${1:?usage: watch.sh events '{\"projectId\":…,\"boardId\":…}' [max_sec]}"
  MAX="${2:-3500}"
  BOARD="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["boardId"])' "${SCOPE}")"
  # Cursor is per-(session,board): two concurrent masters watching the same board must NOT share one
  # cursor file, or one clobbers the other's position and silently skips the events it advanced past.
  CURSORF="${STATE}/cursor-${SID}-${BOARD}"
  if [ ! -f "${CURSORF}" ]; then
    out="$("${DIR}/mcp.sh" wait_for_updates "${SCOPE}")" || { printf '%s\n' "${out}" >&2; exit 1; }
    printf '%s' "${out}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["cursor"], end="")' > "${CURSORF}"
  fi
  start=${SECONDS}
  while (( SECONDS - start < MAX )); do
    cursor="$(cat "${CURSORF}")"
    args="$(python3 -c 'import json,sys; a=json.loads(sys.argv[1]); a["sinceCursor"]=sys.argv[2]; a["timeoutSec"]=50; print(json.dumps(a))' "${SCOPE}" "${cursor}")"
    out="$("${DIR}/mcp.sh" wait_for_updates "${args}")" || { printf '%s\n' "${out}" >&2; exit 1; }
    if printf '%s' "${out}" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("events") else 1)'; then
      printf '%s' "${out}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["cursor"], end="")' > "${CURSORF}"
      printf '%s\n' "${out}"; exit 0
    fi
  done
  echo "watch: no board events before the ${MAX}s deadline (re-run to keep waiting)" >&2
  exit 3
  ;;
tasks)
  SCOPE="${1:?usage: watch.sh tasks '{\"projectId\":…,\"boardId\":…}' 'T-a,T-b|all' [max_sec] [interval_sec]}"
  WATCH="${2:-all}"
  MAX="${3:-540}"
  INT="${4:-20}"
  SCOPE="$(python3 -c 'import json,sys; a=json.loads(sys.argv[1]); a.setdefault("limit",200); print(json.dumps(a))' "${SCOPE}")"
  prev="$("${DIR}/mcp.sh" list_tasks "${SCOPE}")" || { printf '%s\n' "${prev}" >&2; exit 1; }
  start=${SECONDS}
  while (( SECONDS - start < MAX )); do
    sleep "${INT}"
    cur="$("${DIR}/mcp.sh" list_tasks "${SCOPE}")" || { printf '%s\n' "${cur}" >&2; exit 1; }
    changed="$(PREV="${prev}" CUR="${cur}" WATCH="${WATCH}" python3 <<'PY'
import json, os
def idx(raw):
    d = json.loads(raw)
    ts = d.get("tasks", d if isinstance(d, list) else [])
    return {t.get("taskId") or t.get("id"): t for t in ts}
watch = os.environ["WATCH"]
want = None if watch == "all" else {w.strip() for w in watch.split(",") if w.strip()}
prev, cur = idx(os.environ["PREV"]), idx(os.environ["CUR"])
out = [t for tid, t in cur.items()
       if (want is None or tid in want)
       and (tid not in prev or prev[tid].get("status") != t.get("status"))]
print(json.dumps(out))
PY
)"
    if [ "${changed}" != "[]" ]; then
      printf '{"changed":%s}\n' "${changed}"; exit 0
    fi
    prev="${cur}"
  done
  echo "watch: no status change before the ${MAX}s deadline (re-run to keep waiting)" >&2
  exit 3
  ;;
*)
  echo "usage: watch.sh work|events|tasks …" >&2; exit 2
  ;;
esac

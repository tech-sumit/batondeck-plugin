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
# Shared derivation, and it PINS the payload value so the waiter (which never sees a payload) lands
# on the same delivery filename this listener is about to write.
BD_SID_HINT="${sid}"
. "$(cd "$(dirname "$0")" && pwd)/session-id.sh"
sid="${BD_SID}"

command -v node >/dev/null 2>&1 || { echo "[batondeck] wake listener needs node; skipping" >&2; exit 0; }
[ -f "$here/wake-listener.cjs" ] || { echo "[batondeck] wake-listener.cjs missing from this install; skipping" >&2; exit 0; }

state="${BATONDECK_STATE_DIR:-${TMPDIR:-/tmp}/batondeck}"; mkdir -p "$state" 2>/dev/null || true
pidf="$state/wake-$sid.pid"
# Idempotent: one listener per session, however many times SessionStart fires.
if [ -f "$pidf" ] && kill -0 "$(cat "$pidf" 2>/dev/null)" 2>/dev/null; then exit 0; fi

# *** THE AGENT ID IS LOAD-BEARING HERE, NOT DECORATION. *** The listener resolves which wake
# subscription to attach to from BATONDECK_AGENT_ID (skill/wake-listener/main.mjs). While every
# worktree on a machine shared ONE id this could be omitted and still work by accident; now that
# identity is per-worktree, omitting it attaches this session to whichever SIBLING worktree the
# server resolves instead — the agent parks forever and its own doorbell rings a subscription
# nobody pulls. That is the product's only delivery path since T-177, so it fails silently and
# totally. `agent-id.sh` sits in this directory and answers for the checkout we were launched in.
aid="${BATONDECK_AGENT_ID:-$(bash "$here/agent-id.sh" "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null)}"
# A BLANK id is not a degraded mode, it is the original outage: the listener omits the header
# entirely when the value is empty (`...(agentId ? {header} : {})`), so the core falls back to the
# most-recently-active session — the sibling-worktree misroute. Say so and skip rather than
# starting a listener that will attach to somebody else's channel.
if [ -z "$aid" ]; then
  echo "[batondeck] could not resolve an agent id for ${CLAUDE_PROJECT_DIR:-$PWD}; not starting a listener that would attach to the wrong session" >&2
  exit 0
fi
BATONDECK_SESSION_ID="$sid" BATONDECK_AGENT_ID="$aid" \
  nohup node "$here/wake-listener.cjs" >"$state/wake-$sid.log" 2>&1 &
echo $! > "$pidf"
exit 0

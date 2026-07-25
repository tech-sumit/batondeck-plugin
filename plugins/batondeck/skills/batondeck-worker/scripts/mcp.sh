#!/usr/bin/env bash
# batondeck-worker skill — minimal one-shot MCP tool caller. Call one tool, print its
# structuredContent JSON. Self-contained: no dependency on any particular deployment.
# Reuses a cached MCP session (+Cloud Run affinity cookie) across calls — 1 HTTP round-trip per call
# instead of 3; transparently re-initializes and retries ONCE on a session/transport error (never on
# a tool error, which already executed).
#
# Usage:   scripts/mcp.sh <tool_name> '<json-args>'
# Example: scripts/mcp.sh next_task '{"projectId":"P-…","boardId":"B-…"}'
#
# Recommended auth is the BatonDeck plugin's MCP OAuth; this caller is for direct/headless shell use.
# Connection (env):
#   BATONDECK_CORE_URL     core base URL (default: the hosted reference instance)
#   BATONDECK_TOKEN        Google ID token, audience = core URL (bring your own), OR leave unset to mint
#                          one for your ACTIVE gcloud principal (no service-account impersonation)
#   BATONDECK_AGENT        optional display NAME (humans see/assign to it). Free to change at any time —
#                          presence is keyed by the stable id below, so a rename updates one row in place.
#   BATONDECK_AGENT_ID     optional STABLE per-agent id ("deviceId beneath the name"). If unset, a UUID is
#                          generated once and persisted under ${BATONDECK_STATE_DIR:-$HOME/.batondeck} and
#                          reused across runs. Reset for a fresh session: rm that file, or set this var.
set -euo pipefail

TOOL="${1:?usage: mcp.sh <tool> <json-args>}"
ARGS="${2:-}"; [ -n "${ARGS}" ] || ARGS='{}'
# BATONDECK_* is canonical. CONDUCTOR_* is the pre-rename spelling, still honoured below so existing
# setups keep working — delete the shim once nothing sets the old names.
for _v in TOKEN CORE_URL AGENT AGENT_ID PROJECT BOARD STATE_DIR; do
  _b="BATONDECK_${_v}"; _c="CONDUCTOR_${_v}"
  [ -z "${!_b:-}" ] && [ -n "${!_c:-}" ] && export "${_b}=${!_c}"
done
unset _v _b _c
CORE="${BATONDECK_CORE_URL:-${CONDUCTOR_CORE_URL:-https://conductor-core-hn5syhhsja-el.a.run.app}}"

if [ -z "${BATONDECK_TOKEN:-}" ]; then
  BATONDECK_TOKEN="$(gcloud auth print-identity-token --audiences="${CORE}" 2>/dev/null || true)"
fi
# NOTE: `gcloud auth print-identity-token --audiences=…` only works for a SERVICE ACCOUNT principal —
# a normal user login fails with "Invalid account type for --audiences". So do NOT tell the user to run
# `gcloud auth login`; that is the one remedy guaranteed not to help here.
[ -n "${BATONDECK_TOKEN:-}" ] || {
  cat >&2 <<'MSG'
ERROR: no BATONDECK_TOKEN, and none could be minted.

This headless caller needs an audience-scoped Google ID token. Pick one:
  * Service account (headless/CI):  gcloud auth activate-service-account --key-file=KEY.json
    then re-run. Grant it access first with scripts/onboard-agent.sh <sa-email>.
  * Bring your own:                 export BATONDECK_TOKEN="$(... your ID token ...)"
  * Interactive agent use:          prefer the BatonDeck plugin's MCP OAuth over this script.

A plain `gcloud auth login` user account CANNOT mint one (gcloud rejects --audiences for
user principals), so re-running it will not fix this.
MSG
  exit 1
}

DIR="${BATONDECK_STATE_DIR:-$HOME/.batondeck}"; mkdir -p "${DIR}" 2>/dev/null || true

# Stable per-agent id: persist once and reuse so renames/token-refreshes keep ONE presence row (the
# name floats on top). It is NOT a credential — the bearer identity stays the only security boundary.
if [ -z "${BATONDECK_AGENT_ID:-}" ]; then
  AID_FILE="${DIR}/agent-id"
  if [ -f "${AID_FILE}" ]; then
    BATONDECK_AGENT_ID="$(cat "${AID_FILE}")"
  else
    BATONDECK_AGENT_ID="$(uuidgen 2>/dev/null || python3 -c 'import uuid;print(uuid.uuid4())')"
    printf '%s' "${BATONDECK_AGENT_ID}" > "${AID_FILE}" 2>/dev/null || true
  fi
fi

hdr=(-H "authorization: Bearer ${BATONDECK_TOKEN}" -H "content-type: application/json" -H "accept: application/json, text/event-stream")
# Stamp as agent traffic so the core logs this as an MCP agent session (the human UI BFF is unstamped).
hdr+=(-H "x-batondeck-source: agent")
[ -n "${BATONDECK_AGENT_ID:-}" ] && hdr+=(-H "x-batondeck-agent-id: ${BATONDECK_AGENT_ID}")
[ -n "${BATONDECK_AGENT:-}" ] && hdr+=(-H "x-batondeck-agent: ${BATONDECK_AGENT}")

# Cached session + affinity-cookie jar, keyed by core URL + scope. Concurrent callers share them; a
# stale entry is healed by the retry path below. Long-poll loops (watch.sh) set MCP_SESSION_SCOPE to
# an isolated value: on the STATEFUL path, a parked long-poll and an interactive call overlapping on
# one session can leave the long-poll's SSE stream unclosed after its response.
KEY="$(printf '%s|%s' "${CORE}" "${MCP_SESSION_SCOPE:-main}" | cksum | awk '{print $1}')"
SFILE="${DIR}/sess-${KEY}"; JAR="${DIR}/jar-${KEY}"
cj=(-c "${JAR}" -b "${JAR}")

# Never abort on a failed init (set -e would surface curl's raw exit code) — leave sid empty and let
# call_once report a clean TRANSPORT_ERROR through the normal retry/exit path.
init_session() {
  : > "${JAR}"
  sid="$({ curl -s -D - -o /dev/null "${cj[@]}" -X POST "${CORE}/mcp" "${hdr[@]}" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"mcp.sh","version":"1"}}}' \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}'; } || true)"
  curl -s -o /dev/null "${cj[@]}" -X POST "${CORE}/mcp" "${hdr[@]}" -H "mcp-session-id: ${sid}" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' || true
  printf '%s' "${sid}" > "${SFILE}" 2>/dev/null || true
}

req=$(python3 -c "import json,sys; print(json.dumps({'jsonrpc':'2.0','id':2,'method':'tools/call','params':{'name':sys.argv[1],'arguments':json.loads(sys.argv[2])}}))" "${TOOL}" "${ARGS}")

# Parser exit codes: 0 = ok · 1 = tool error (call EXECUTED — never retried) · 90 = SESSION-loss RPC
# error (invalid/expired mcp-session-id → the server rejected the call BEFORE executing, so re-init +
# retry is safe) · 91 = other RPC error (quota / rate-limit / invalid params — surface, do NOT retry) ·
# 92 = transport error (EOF / ambiguous cut — the call may have committed; only retry for read-only
# tools). The parser acts on the FIRST complete JSON-RPC response and exits — it never waits for EOF.
call_once() {
  curl -s -N --max-time 120 "${cj[@]}" -X POST "${CORE}/mcp" "${hdr[@]}" -H "mcp-session-id: ${sid}" -d "${req}" \
    | python3 -u -c "
import sys, json

def handle(d):
    if 'error' in d:
        e = d['error']
        msg = (e.get('message','') if isinstance(e, dict) else str(e)).lower()
        # Session-loss is the only RPC error safe to re-issue (rejected pre-execution). Everything else
        # (quota, rate-limit, validation) executed-or-not is NOT blindly retryable.
        if 'session' in msg:
            print('SESSION_ERROR:', json.dumps(e)); sys.exit(90)
        print('RPC_ERROR:', json.dumps(e)); sys.exit(91)
    r = d.get('result') or {}
    if r.get('isError'):
        print('TOOL_ERROR:', r['content'][0]['text']); sys.exit(1)
    print(json.dumps(r.get('structuredContent', r), indent=2)); sys.exit(0)

raw = []
for line in sys.stdin:  # SSE framing: act on each data: payload as it lands
    raw.append(line)
    if line.startswith('data: '):
        try:
            d = json.loads(line[6:].strip())
        except Exception:
            continue
        if 'error' in d or 'result' in d:
            handle(d)
# EOF without a response event: maybe a plain (non-SSE) JSON body, else an ambiguous transport cut.
try:
    handle(json.loads(''.join(raw)))
except SystemExit:
    raise
except Exception:
    print('TRANSPORT_ERROR:', ''.join(raw).strip()[:400]); sys.exit(92)"
  # Early parser exit SIGPIPEs curl (141 under pipefail) — the parser's status is the call's status.
  return "${PIPESTATUS[1]}"
}

# Is a transport cut on THIS tool safe to retry? Only for read-only / idempotent tools — a mutation
# that committed before the response was lost must NOT be re-issued (it would duplicate).
case " next_task wait_for_task wait_for_updates rank_tasks search_tasks get_task get_board get_project get_transitions get_task_context list_tasks list_boards list_projects list_subtasks list_attachments list_comments list_follow_ups list_runs list_notifications read_memory get_skill_stats list_agent_sessions " in
  *" ${TOOL} "*) retry_transport=1 ;;
  *) retry_transport=0 ;;
esac

sid="$(cat "${SFILE}" 2>/dev/null || true)"
[ -n "${sid}" ] || init_session

set +e; out="$(call_once)"; rc=$?; set -e
# Retry ONCE on session loss (always safe), or on a transport cut only for read-only tools.
if [ "${rc}" -eq 90 ] || { [ "${rc}" -eq 92 ] && [ "${retry_transport}" -eq 1 ]; }; then
  init_session
  set +e; out="$(call_once)"; rc=$?; set -e
fi
printf '%s\n' "${out}"
[ "${rc}" -eq 0 ] || exit 1

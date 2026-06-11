#!/usr/bin/env bash
# conductor-worker skill — minimal one-shot MCP tool caller. Initialize a session, call one tool,
# print its structuredContent JSON. Self-contained: no dependency on any particular deployment.
#
# Usage:   scripts/mcp.sh <tool_name> '<json-args>'
# Example: scripts/mcp.sh next_task '{"projectId":"P-…","boardId":"B-…"}'
#
# Connection (env):
#   CONDUCTOR_CORE_URL     core base URL (default: the hosted reference instance)
#   CONDUCTOR_TOKEN        Google ID token, audience = core URL (bring your own), OR leave unset to mint:
#   CONDUCTOR_AGENT_SA       mint by impersonating this service account (your agent's SA)
#                            (else mint for the active gcloud principal)
#   CONDUCTOR_ON_BEHALF_OF  optional on-behalf-of identity (only when authing as a trusted gateway SA)
set -euo pipefail

TOOL="${1:?usage: mcp.sh <tool> <json-args>}"
ARGS="${2:-}"; [ -n "${ARGS}" ] || ARGS='{}'
CORE="${CONDUCTOR_CORE_URL:-https://conductor-core-hn5syhhsja-el.a.run.app}"

if [ -z "${CONDUCTOR_TOKEN:-}" ]; then
  if [ -n "${CONDUCTOR_AGENT_SA:-}" ]; then
    CONDUCTOR_TOKEN="$(gcloud auth print-identity-token --impersonate-service-account="${CONDUCTOR_AGENT_SA}" --audiences="${CORE}" --include-email 2>/dev/null || true)"
  else
    CONDUCTOR_TOKEN="$(gcloud auth print-identity-token --audiences="${CORE}" 2>/dev/null || true)"
  fi
fi
[ -n "${CONDUCTOR_TOKEN:-}" ] || { echo "ERROR: no CONDUCTOR_TOKEN (set it, or set CONDUCTOR_AGENT_SA to mint one)." >&2; exit 1; }

hdr=(-H "authorization: Bearer ${CONDUCTOR_TOKEN}" -H "content-type: application/json" -H "accept: application/json, text/event-stream")
[ -n "${CONDUCTOR_ON_BEHALF_OF:-}" ] && hdr+=(-H "x-conductor-on-behalf-of: ${CONDUCTOR_ON_BEHALF_OF}")

# Carry Cloud Run's affinity cookie across the 3 requests so the in-process MCP session sticks.
JAR="$(mktemp)"; trap 'rm -f "${JAR}"' EXIT
cj=(-c "${JAR}" -b "${JAR}")

sid="$(curl -s -D - -o /dev/null "${cj[@]}" -X POST "${CORE}/mcp" "${hdr[@]}" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"mcp.sh","version":"1"}}}' \
  | tr -d '\r' | awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}')"
curl -s -o /dev/null "${cj[@]}" -X POST "${CORE}/mcp" "${hdr[@]}" -H "mcp-session-id: ${sid}" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'

req=$(python3 -c "import json,sys; print(json.dumps({'jsonrpc':'2.0','id':2,'method':'tools/call','params':{'name':sys.argv[1],'arguments':json.loads(sys.argv[2])}}))" "${TOOL}" "${ARGS}")
curl -s -N "${cj[@]}" -X POST "${CORE}/mcp" "${hdr[@]}" -H "mcp-session-id: ${sid}" -d "${req}" \
  | sed -n 's/^data: //p' \
  | python3 -c "import sys,json
d=json.load(sys.stdin)
if 'error' in d: print('ERROR:', json.dumps(d['error'])); sys.exit(1)
r=d['result']
if r.get('isError'): print('TOOL_ERROR:', r['content'][0]['text']); sys.exit(1)
print(json.dumps(r.get('structuredContent', r), indent=2))"

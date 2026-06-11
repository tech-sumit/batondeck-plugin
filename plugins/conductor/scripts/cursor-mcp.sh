#!/usr/bin/env bash
# conductor-skill — native MCP launcher for Cursor (and any stdio MCP client).
# Mints a Google ID token (audience = core URL) and bridges the client's stdio MCP transport to the
# Conductor core's Streamable HTTP /mcp endpoint via `mcp-remote`. The token lasts ~1h — restart the
# MCP server in Cursor (Settings → MCP → reload) to refresh it.
#
# Env (same as the other scripts):
#   CONDUCTOR_CORE_URL      core base URL (default: hosted reference instance)
#   CONDUCTOR_TOKEN         a Google ID token (audience = core URL); else minted below
#   CONDUCTOR_AGENT_SA      mint by impersonating this service account (else the active gcloud principal)
#   CONDUCTOR_ON_BEHALF_OF  optional on-behalf-of identity (only when authing as a trusted gateway SA)
set -euo pipefail
CORE="${CONDUCTOR_CORE_URL:-https://conductor-core-hn5syhhsja-el.a.run.app}"

if [ -n "${CONDUCTOR_TOKEN:-}" ]; then
  TOKEN="${CONDUCTOR_TOKEN}"
elif [ -n "${CONDUCTOR_AGENT_SA:-}" ]; then
  TOKEN="$(gcloud auth print-identity-token --impersonate-service-account="${CONDUCTOR_AGENT_SA}" --audiences="${CORE}" --include-email)"
else
  TOKEN="$(gcloud auth print-identity-token --audiences="${CORE}")"
fi
[ -n "${TOKEN}" ] || { echo "conductor: could not mint a token (check gcloud auth / CONDUCTOR_AGENT_SA)" >&2; exit 1; }

args=("${CORE}/mcp" --header "Authorization: Bearer ${TOKEN}")
[ -n "${CONDUCTOR_ON_BEHALF_OF:-}" ] && args+=(--header "x-conductor-on-behalf-of: ${CONDUCTOR_ON_BEHALF_OF}")

exec npx -y mcp-remote "${args[@]}"

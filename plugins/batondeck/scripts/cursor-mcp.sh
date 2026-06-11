#!/usr/bin/env bash
# batondeck-skill — native MCP launcher for Cursor (and any stdio MCP client).
# Mints a Google ID token (audience = core URL) and bridges the client's stdio MCP transport to the
# BatonDeck core's Streamable HTTP /mcp endpoint via `mcp-remote`. The token lasts ~1h — restart the
# MCP server in Cursor (Settings → MCP → reload) to refresh it.
#
# Env (same as the other scripts):
#   BATONDECK_CORE_URL      core base URL (default: hosted reference instance)
#   BATONDECK_TOKEN         a Google ID token (audience = core URL); else minted below
#   BATONDECK_AGENT_SA      mint by impersonating this service account (else the active gcloud principal)
#   BATONDECK_ON_BEHALF_OF  optional on-behalf-of identity (only when authing as a trusted gateway SA)
set -euo pipefail
CORE="${BATONDECK_CORE_URL:-https://mcp.batondeck.com}"

if [ -n "${BATONDECK_TOKEN:-}" ]; then
  TOKEN="${BATONDECK_TOKEN}"
elif [ -n "${BATONDECK_AGENT_SA:-}" ]; then
  TOKEN="$(gcloud auth print-identity-token --impersonate-service-account="${BATONDECK_AGENT_SA}" --audiences="${CORE}" --include-email)"
else
  TOKEN="$(gcloud auth print-identity-token --audiences="${CORE}")"
fi
[ -n "${TOKEN}" ] || { echo "batondeck: could not mint a token (check gcloud auth / BATONDECK_AGENT_SA)" >&2; exit 1; }

args=("${CORE}/mcp" --header "Authorization: Bearer ${TOKEN}")
[ -n "${BATONDECK_ON_BEHALF_OF:-}" ] && args+=(--header "x-batondeck-on-behalf-of: ${BATONDECK_ON_BEHALF_OF}")

exec npx -y mcp-remote "${args[@]}"

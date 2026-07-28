#!/usr/bin/env bash
# batondeck-skill — native MCP launcher for Cursor (and any stdio MCP client).
# Bridges the client's stdio MCP transport to BatonDeck's Streamable HTTP endpoint via `mcp-remote`.
#
# THIS NO LONGER MINTS A gcloud TOKEN. It used to mint a Google ID token (audience = core URL) and
# point at the IAM-protected core. That path is dead: the core is an OAuth 2.0 resource server and
# verifies `iss == https://mcp.batondeck.com` against that server's JWKS, so a Google-issued ID token
# (`iss = https://accounts.google.com`) fails signature AND issuer — 401 UNAUTHENTICATED, every time.
# See src/auth/verify.ts.
#
# What runs instead: `mcp-remote` against https://mcp.batondeck.com/mcp, which performs the browser
# OAuth flow itself (dynamic client registration + PKCE) and caches the token — the same connection
# the plugin's own .mcp.json uses. Sign in once; no token to paste, no hourly re-mint.
#
# Env:
#   BATONDECK_MCP_URL   endpoint (default: https://mcp.batondeck.com/mcp; set for a self-hosted one)
#   BATONDECK_CORE_URL  legacy: a core BASE url, still honoured — `/mcp` is appended
#   BATONDECK_TOKEN     optional: skip the browser flow with an access token you already hold
#                       (must be issued by the same authorization server, audience = the core URL)
set -euo pipefail
URL="${BATONDECK_MCP_URL:-${BATONDECK_CORE_URL:+${BATONDECK_CORE_URL%/}/mcp}}"
URL="${URL:-https://mcp.batondeck.com/mcp}"

args=("${URL}")
[ -n "${BATONDECK_TOKEN:-}" ] && args+=(--header "Authorization: Bearer ${BATONDECK_TOKEN}")

# Stable per-agent id, so this client is addressable/revocable on its own rather than collapsing into
# the owner's single `id:<identityId>` row. Injected as a LITERAL here on purpose: Cursor is reported
# not to expand `${env:VAR}` inside `headers` for remote http/sse servers, and this stdio wrapper
# sidesteps that question entirely. Empty (unpersistable state dir) → header omitted → old behaviour.
aid="$("$(dirname "$0")/agent-id.sh" 2>/dev/null)"
[ -n "${aid}" ] && args+=(--header "x-batondeck-agent-id: ${aid}")
[ -n "${BATONDECK_AGENT:-}" ] && args+=(--header "x-batondeck-agent: ${BATONDECK_AGENT}")

exec npx -y mcp-remote "${args[@]}"

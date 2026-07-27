#!/usr/bin/env bash
# batondeck-worker skill — print the connection env a DIRECT shell call to the core needs, as exports.
#
# THIS SCRIPT NO LONGER MINTS A TOKEN, because the token it used to mint is rejected. The core is an
# OAuth 2.0 resource server: it accepts only ACCESS TOKENS issued by the BatonDeck MCP authorization
# server (iss = https://mcp.batondeck.com, aud = the core URL, kind "access"), verified against that
# AS's JWKS. A gcloud-minted Google ID token carries iss = https://accounts.google.com and fails both
# the signature and the issuer check — the core answers
#   401 {"jsonrpc":"2.0","error":{"code":-32001,"message":"UNAUTHENTICATED"},"id":null}
# Minting one and handing it over would only produce that 401, so the mint is gone and this script
# fails fast instead. See src/auth/verify.ts.
#
# There is NO headless/CI token flow today: that AS advertises only `authorization_code` (browser
# sign-in) and `refresh_token`. Bring a token, or connect over MCP OAuth (see the error text below).
#
# Usage:  export BATONDECK_TOKEN=<access token>; eval "$(scripts/token.sh)"
# Env:    BATONDECK_CORE_URL — core base URL, default: the hosted instance
set -euo pipefail
CORE="${BATONDECK_CORE_URL:-${CONDUCTOR_CORE_URL:-https://conductor-core-hn5syhhsja-el.a.run.app}}"
TOKEN="${BATONDECK_TOKEN:-${CONDUCTOR_TOKEN:-}}"
[ -n "${TOKEN}" ] || {
  cat >&2 <<'MSG'
ERROR: no BATONDECK_TOKEN — and this script can no longer mint one.

The core accepts only access tokens issued by https://mcp.batondeck.com (aud = the core URL). A
gcloud-minted Google ID token is rejected on its ISSUER, so the old mint here returned a token that
always 401'd. There is no headless token flow today (the authorization server offers only browser
sign-in + refresh). Pick one:

  * MCP OAuth (recommended, works today): point your MCP client at
        https://mcp.batondeck.com/mcp
    The BatonDeck plugin ships this in its .mcp.json; any other stdio client can use
        npx -y mcp-remote https://mcp.batondeck.com/mcp
    Sign in once in the browser; the client then holds the token for you.
  * Bring your own:   export BATONDECK_TOKEN=<access token from https://mcp.batondeck.com>
  * Local dev core:   a core started with AUTH_MODE=dev needs no token at all.

`gcloud auth login` and `gcloud auth activate-service-account` CANNOT help: the core rejects on the
token's issuer, not on which principal minted it.
MSG
  exit 1
}
echo "export BATONDECK_TOKEN=${TOKEN}"
# Carry the RESOLVED core through too: the token's audience is this URL, so mcp.sh must call the same
# host or every request 401s. (mcp.sh accepts both spellings; BATONDECK_* wins.)
echo "export BATONDECK_CORE_URL=${CORE}"

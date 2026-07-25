#!/usr/bin/env bash
# batondeck-worker skill — mint the Google ID token a DIRECT shell call to the core needs, printed as
# exports. Google ID tokens last ~1h; re-run when calls start returning 401.
#
# The recommended way to connect is the BatonDeck plugin's MCP OAuth (browser sign-in, no tokens to
# paste). This helper is only for direct/headless shell calls; it mints a token for your ACTIVE gcloud
# principal — no service-account impersonation. Or set BATONDECK_TOKEN yourself and skip this.
#
# Usage:  eval "$(scripts/token.sh)"      # exports BATONDECK_TOKEN + BATONDECK_TOKEN (aliases)
# Env:    BATONDECK_CORE_URL (or the older BATONDECK_CORE_URL) — core base URL, default: hosted instance
set -euo pipefail
CORE="${BATONDECK_CORE_URL:-${CONDUCTOR_CORE_URL:-https://conductor-core-hn5syhhsja-el.a.run.app}}"
# `|| true` matters: without it `set -e` aborts here and the diagnostic below never prints.
TOKEN="$(gcloud auth print-identity-token --audiences="${CORE}" 2>/dev/null || true)"
# NOTE: `--audiences=…` only works for a SERVICE ACCOUNT principal — a normal user login fails with
# "Invalid account type for --audiences". So do NOT tell the user to run `gcloud auth login`; that is
# the one remedy guaranteed not to help here.
[ -n "${TOKEN}" ] || {
  cat >&2 <<'MSG'
ERROR: could not mint a token.

A direct shell call to the core needs an audience-scoped Google ID token. Pick one:
  * Service account (headless/CI):  gcloud auth activate-service-account --key-file=KEY.json
    then re-run. Grant it access first with scripts/onboard-agent.sh <sa-email>.
  * Bring your own:                 export BATONDECK_TOKEN="$(... your ID token ...)"
  * Interactive agent use:          prefer the BatonDeck plugin's MCP OAuth over this script.

A plain `gcloud auth login` user account CANNOT mint one (gcloud rejects --audiences for
user principals), so re-running it will not fix this.
MSG
  exit 1
}
# Both spellings: BATONDECK_* is the product name; CONDUCTOR_* is what the older scripts read.
echo "export BATONDECK_TOKEN=${TOKEN}"
echo "export BATONDECK_TOKEN=${TOKEN}"
# Carry the RESOLVED core through too: the token's audience is this URL, so mcp.sh must call the same
# host or every request 401s. (mcp.sh accepts both spellings; BATONDECK_* wins.)
echo "export BATONDECK_CORE_URL=${CORE}"
echo "export BATONDECK_CORE_URL=${CORE}"

#!/usr/bin/env bash
# batondeck-worker skill — mint the Google ID token the MCP connection needs and print it as exports.
# Google ID tokens last ~1h; re-run when calls start returning 401.
#
# Usage:  eval "$(scripts/token.sh)"      # exports BATONDECK_TOKEN
# Env:    BATONDECK_CORE_URL  core base URL (default: hosted reference instance)
#         BATONDECK_AGENT_SA  mint by impersonating this service account (your agent's SA);
#                             else mint for the active gcloud principal.
set -euo pipefail
CORE="${BATONDECK_CORE_URL:-https://mcp.batondeck.com}"
if [ -n "${BATONDECK_AGENT_SA:-}" ]; then
  TOKEN="$(gcloud auth print-identity-token --impersonate-service-account="${BATONDECK_AGENT_SA}" --audiences="${CORE}" --include-email 2>/dev/null)"
else
  TOKEN="$(gcloud auth print-identity-token --audiences="${CORE}" 2>/dev/null)"
fi
[ -n "${TOKEN}" ] || { echo "ERROR: could not mint a token (check gcloud auth / BATONDECK_AGENT_SA)." >&2; exit 1; }
echo "export BATONDECK_TOKEN=${TOKEN}"

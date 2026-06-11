#!/usr/bin/env bash
# batondeck-worker skill — mint the Google ID token the MCP connection needs and print it as exports.
# Google ID tokens last ~1h; re-run when calls start returning 401.
#
# Usage:  eval "$(scripts/token.sh)"      # exports CONDUCTOR_TOKEN
# Env:    CONDUCTOR_CORE_URL  core base URL (default: hosted reference instance)
#         CONDUCTOR_AGENT_SA  mint by impersonating this service account (your agent's SA);
#                             else mint for the active gcloud principal.
set -euo pipefail
CORE="${CONDUCTOR_CORE_URL:-https://conductor-core-hn5syhhsja-el.a.run.app}"
if [ -n "${CONDUCTOR_AGENT_SA:-}" ]; then
  TOKEN="$(gcloud auth print-identity-token --impersonate-service-account="${CONDUCTOR_AGENT_SA}" --audiences="${CORE}" --include-email 2>/dev/null)"
else
  TOKEN="$(gcloud auth print-identity-token --audiences="${CORE}" 2>/dev/null)"
fi
[ -n "${TOKEN}" ] || { echo "ERROR: could not mint a token (check gcloud auth / CONDUCTOR_AGENT_SA)." >&2; exit 1; }
echo "export CONDUCTOR_TOKEN=${TOKEN}"

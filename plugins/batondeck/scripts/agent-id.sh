#!/usr/bin/env bash
# BatonDeck plugin — the agent's STABLE identity, generated once and presented on every connect.
#
#   agent-id.sh             print the agent id (bare string)
#   agent-id.sh --headers   print the MCP connection headers as JSON  <- `headersHelper` in .mcp.json
#
# WHY THIS EXISTS. `.mcp.json` is static JSON, so the plugin could only ever send a literal or an
# environment variable — neither can "generate a UUID once and reuse it forever". Claude Code's
# `headersHelper` runs a command at connect time and merges its JSON stdout into the request headers,
# which is exactly the missing hook. Without it every plugin user collapses to the server's last-resort
# handle `id:<identityId>`: ONE agent row per human, so wake routing cannot address a single agent,
# `disconnect_agent` revokes all of them at once, and per-agent stats are meaningless.
#
# THE ID IS NOT A CREDENTIAL. The verified bearer identity remains the only security boundary; this is
# an addressing key namespaced under it. Forging it can at most mislabel the caller's OWN agents.
#
# CONTRACT SHARED WITH scripts/mcp.sh: both read/write the SAME file —
# `${BATONDECK_STATE_DIR:-$HOME/.batondeck}/agent-id` — so the curl path and the MCP path present the
# same agent. The shared thing is that PATH, not this code; keep the two spellings equal.
#
# No `set -e`: a headersHelper that dies before printing costs the user their agent id. Every step
# below is individually tolerant and the script always reaches its final print.
set -u

dir="${BATONDECK_STATE_DIR:-${HOME:-/tmp}/.batondeck}"
file="${dir}/agent-id"

id="${BATONDECK_AGENT_ID:-}"

if [ -z "${id}" ]; then
  mkdir -p "${dir}" 2>/dev/null
  id="$(cat "${file}" 2>/dev/null)" || id=""
  # Stripped HERE, before the emptiness test below — not only at the end. A ZERO-BYTE or
  # whitespace-only file yields no usable id, and it has to read as ABSENT so the mint path heals it.
  id="$(printf '%s' "${id}" | tr -d '[:space:]')"
fi

if [ -z "${id}" ]; then
  new="$(uuidgen 2>/dev/null || python3 -c 'import uuid;print(uuid.uuid4())' 2>/dev/null)"
  # noclobber makes `>` an atomic O_EXCL create: if two clients start at once, exactly one write wins
  # and the loser falls through to read the winner's value, so both present the SAME id.
  if [ -n "${new}" ]; then
    # WITHOUT THIS rm, AN UNUSABLE FILE IS PERMANENT. noclobber's O_EXCL refuses to replace it, the
    # re-read below returns empty again, and the helper emits `{}` on EVERY connect forever — the agent
    # silently collapses to `id:<identity>`, which is the exact failure T-81 was built to fix. It is
    # reachable: a create-then-write (as skill/scripts/mcp.sh did) leaves 0 bytes if the process dies
    # between the two. Guarded by the `-z` above, so a usable id is never removed. Residual: a racing
    # sibling that created the file microseconds ago can have it removed here — it then re-reads empty
    # and emits `{}` ONCE, healing on the next connect. Strictly better than never healing.
    rm -f "${file}" 2>/dev/null
    ( set -o noclobber; printf '%s' "${new}" > "${file}" ) 2>/dev/null
    id="$(cat "${file}" 2>/dev/null)" || id=""
  fi
fi

# Whitespace (a trailing newline from a hand-edited file) would become part of the routing key. Also
# covers BATONDECK_AGENT_ID, which skips both blocks above.
id="$(printf '%s' "${id}" | tr -d '[:space:]')"

# DELIBERATE: if the id could not be persisted (read-only HOME, no uuidgen), emit NOTHING rather than a
# fresh random id. An unpersisted id would be new on every connect — forking presence and orphaning the
# previous wake subscription to its TTL every session, which is worse than today's collapsed-but-stable
# `id:<identityId>` fallback. Silence degrades to exactly today's behaviour.

if [ "${1:-}" = "--headers" ]; then
  # A blank/absent header is the legitimate "no id" case server-side, so an empty object is safe.
  # Claude Code tolerates a helper that fails, prints nothing, or prints garbage: it connects without
  # the extra headers (verified against 2.1.220). So the worst case here is today's behaviour.
  python3 - "${id}" "${BATONDECK_AGENT:-}" <<'PY' 2>/dev/null || printf '{}\n'
import json, sys
aid, name = sys.argv[1].strip(), sys.argv[2].strip()
h = {}
if aid:
    h['x-batondeck-agent-id'] = aid[:64]
if name:
    h['x-batondeck-agent'] = name[:64]
print(json.dumps(h))
PY
else
  printf '%s\n' "${id}"
fi

# Rotate (the only way back from a sticky `disconnect_agent`):
#     rm ~/.batondeck/agent-id        then restart the MCP client
# The next connect mints a new id; the old one stays disconnected, which is the point.

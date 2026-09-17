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
#   BATONDECK_TOKEN        REQUIRED: an access token issued by https://mcp.batondeck.com, audience =
#                          core URL. Nothing is minted here — the gcloud ID token this used to mint is
#                          rejected by the core (see the error text below). A core running
#                          AUTH_MODE=dev ignores the value, so any placeholder satisfies the check.
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

# NO MINT HERE, DELIBERATELY. The core accepts only access tokens issued by the BatonDeck MCP
# authorization server (iss = https://mcp.batondeck.com, aud = core URL, kind "access"). The gcloud
# ID token this script used to mint carries iss = https://accounts.google.com and is rejected on the
# issuer — 401 UNAUTHENTICATED, every time. See src/auth/verify.ts.
[ -n "${BATONDECK_TOKEN:-}" ] || {
  cat >&2 <<'MSG'
ERROR: no BATONDECK_TOKEN — and this caller no longer mints one, because the token it used to mint
is rejected by the core on its ISSUER (gcloud Google ID token vs the required
https://mcp.batondeck.com access token). There is no headless token flow today: the authorization
server offers only browser sign-in + refresh. Pick one:

  * MCP OAuth (recommended, works today): point your MCP client at
        https://mcp.batondeck.com/mcp
    The BatonDeck plugin ships this in its .mcp.json; any other stdio client can use
        npx -y mcp-remote https://mcp.batondeck.com/mcp
  * Bring your own:   export BATONDECK_TOKEN=<access token from https://mcp.batondeck.com>
  * Local dev core:   AUTH_MODE=dev ignores the token — export BATONDECK_TOKEN=dev to get past here.

`gcloud auth login` and `gcloud auth activate-service-account` CANNOT help: the core rejects on the
token's issuer, not on which principal minted it.
MSG
  exit 1
}

DIR="${BATONDECK_STATE_DIR:-$HOME/.batondeck}"; mkdir -p "${DIR}" 2>/dev/null || true
BD_DIR="${DIR}"
# No project argument on this path: a curl caller is already standing in the checkout it means.
BD_PROJ=""
# HARNESS PREFIX. `CLAUDECODE` is a MEASURED marker (it is set in a Claude Code shell, alongside
# CLAUDE_CODE_ENTRYPOINT). No other harness has a marker this repo has measured, so everything else
# is `mcp` unless the caller says otherwise: inventing env-var names for harnesses nobody here can
# test would be a guess wearing a detection's clothes, and it would mislabel agents confidently.
# Set BATONDECK_AGENT_PREFIX to your harness — cursor, codex, chatgpt, gemini, antigravity,
# openhands, opencode, claude-desktop, ...
BD_PREFIX="${BATONDECK_AGENT_PREFIX:-}"
if [ -z "${BD_PREFIX}" ] && [ -n "${CLAUDECODE:-}" ]; then BD_PREFIX="claude"; fi
# --- BEGIN bd-agent-identity ---------------------------------------------------------------------
# BYTE-IDENTICAL in plugin/scripts/agent-id.sh and skill/scripts/mcp.sh. scripts/testkit/agent-id-test.sh
# extracts both copies and diffs them, so changing one without the other fails the gate. Reads BD_DIR
# and BD_PROJ; sets BD_ID_FILE and BD_AGENT_NAME.
#
# WHY. One machine runs many agents — one per git worktree — and every one of them collapsed onto a
# single `${BD_DIR}/agent-id`. The board could not tell which worktree was building what, a
# `disconnect_agent` hit all of them at once, and per-agent wake routing addressed a row shared by
# every lane.
#
# KEYED ON THE WORKTREE, NEVER THE BRANCH. `publishAssignment` resolves the doorbell by DISPLAY NAME
# (src/wake/publisher.ts), so a name that moved on `git checkout` would re-point the row the board is
# already addressing — the agent would be renamed out from under its own assignment. A worktree's git
# dir does not move when the branch does, and git already guarantees its basename unique within the
# repository, which is why that is the key rather than the branch or the directory name.
#
# THE MAIN CHECKOUT IS DELIBERATELY UNCHANGED — legacy file, no default name. Rotating an existing
# user's id forks presence and orphans their wake subscription to its TTL, for no benefit to them.
# ONE sanitizer for every value that becomes a header or a path segment. Defined here, in the shared
# block, so the two scripts cannot drift — and so a new value cannot be added without one.
#
# *** WHY `tr` IS IN FRONT, AND WHY THIS IS NOT PEDANTRY. *** The previous pipelines were `sed | cut`,
# and BOTH ARE LINE-ORIENTED: sed never sees the record separator in its pattern space, and `cut -c`
# truncates PER LINE, so the length cap does not help either. Measured: `printf 'foo\nbar'` came out of
# `sed 's/[^A-Za-z0-9.-]/-/g' | cut -c1-24` completely unchanged. CR, NUL and TAB were replaced; LF was
# the unique survivor — and the block's own comment already declared that "an unsanitized LF here would
# split the header". It was enforced on exactly one of six values.
# LC_ALL=C on every stage: sed's character class is byte-wise in C and collating-character-wise in a
# UTF-8 locale, so an unpinned stage makes one worktree yield two identities depending on inherited LANG.
bd_sanitize() { # $1 = max chars; value on stdin
  LC_ALL=C tr -d '\000-\037' | LC_ALL=C sed 's/[^A-Za-z0-9._-]/-/g' | LC_ALL=C cut -c1-"$1"
}
BD_ID_FILE="${BD_DIR}/agent-id"
BD_AGENT_NAME=""
# The HARNESS PREFIX rides in from the caller, which is the only half that differs between the two
# scripts (one always runs under Claude Code, the other under whatever launched it). Sanitized HERE
# so both spellings agree on what a prefix may contain — `claude-desktop` keeps its hyphen.
# LC_ALL=C on BOTH sanitizers is not style. `sed`'s character class is byte-at-a-time in the C
# locale and collating-character-wise in a UTF-8 one, so a worktree named `café` sanitizes to
# `caf--` with no locale set and `caf-` under en_US.UTF-8 — two ids and two display names for
# ONE lane, decided by whether the process inherited LANG. A GUI-launched MCP client and the
# same user's terminal disagree. The `||` fallback matters too: this is the only substitution
# in the block without one, and mcp.sh runs `set -euo pipefail`, so a sed failure there killed
# the caller outright while agent-id.sh (no `set -e`) degraded quietly — byte-identical text,
# different behaviour.
BD_PREFIX="$(printf '%s' "${BD_PREFIX}" | bd_sanitize 24)" || BD_PREFIX=""

# *** STRIP CONTROL BYTES FROM ANY CALLER-SUPPLIED VALUE THAT BECOMES AN HTTP HEADER. ***
# Measured on the wire, curl 8.7.1: `-H "x-batondeck-agent: evil<CR><LF>x-injected: yes"` is emitted
# as TWO headers, with the injected line landing BEFORE the legitimate one. Both variables reach a
# header verbatim in three producers (mcp.sh's curl, cursor-mcp.sh's `mcp-remote --header`, and
# agent-id.sh --headers' JSON, which the client decodes back to a literal LF). Cleaned ONCE here, in
# the block every producer carries byte-identically, rather than per producer — sanitizing one of
# three places is how the derived name became inconsistent in the first place.
#
# SCOPE, deliberately understated: this is a CORRECTNESS fix, NOT a privilege fix. mcp.sh runs with the
# caller's OWN environment, so anyone who can set these could add `-H` directly; every header reachable
# this way is already documented caller-settable and untrusted (src/security/signals.ts:212); and Node's
# llhttp rejects control bytes in a header VALUE, so the value path was never the exposure. What this
# buys is that a name with a stray newline becomes a clean name instead of two headers.
#
# CONTROL BYTES ONLY — NOT bd_sanitize. A display name legitimately contains spaces ("Claude Worker 1"
# is a documented ASSIGNEE shape, plugin/scripts/listener-start.sh), and the full sanitizer would
# corrupt honest input and break the exact-name match the doorbell resolves on.
bd_hdr_safe() { LC_ALL=C tr -d '\000-\037\177'; }
[ -z "${BATONDECK_AGENT:-}" ]    || BATONDECK_AGENT="$(printf '%s' "${BATONDECK_AGENT}" | bd_hdr_safe)"
[ -z "${BATONDECK_AGENT_ID:-}" ] || BATONDECK_AGENT_ID="$(printf '%s' "${BATONDECK_AGENT_ID}" | bd_hdr_safe)"
[ -n "${BD_PREFIX}" ] || BD_PREFIX="mcp"
# An MCP client that does not expand `${CLAUDE_PROJECT_DIR}` hands the literal string through, so
# anything still carrying a `${` counts as ABSENT and we fall back — env var, then cwd.
case "${BD_PROJ}" in *'${'*|'') BD_PROJ="${CLAUDE_PROJECT_DIR:-}" ;; esac
case "${BD_PROJ}" in *'${'*|'') BD_PROJ="." ;; esac
# `env -u` IS LOAD-BEARING: git honours an inherited GIT_DIR **over** an explicit `-C`, so under any
# git-invoked process (a hook, `git rebase -x`, a CI step inside a git callback) this probe would
# answer for the INHERITED repo whatever directory it was handed — attributing the identity to the
# wrong checkout. Measured: `git -C / rev-parse --absolute-git-dir` fails normally and returns the
# inherited git dir with GIT_DIR set. Found by pre-push, which runs as exactly such a process.
BD_GIT_DIR="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR -u GIT_OBJECT_DIRECTORY git -C "${BD_PROJ}" rev-parse --absolute-git-dir 2>/dev/null)" || BD_GIT_DIR=""
# A LINKED worktree's git dir is `<common>/worktrees/<name>`; the main checkout's is `<repo>/.git`.
if [ -n "${BD_GIT_DIR}" ] && [ "$(basename "$(dirname "${BD_GIT_DIR}")" 2>/dev/null)" = "worktrees" ]; then
  BD_WT="$(basename "${BD_GIT_DIR}" | bd_sanitize 40)" || BD_WT=""
  # Two repositories can each hold a worktree named `foo`, so the FILE is keyed on the absolute path
  # as well: the readable half is for whoever runs `ls`, the checksum is what makes it unique.
  BD_WT_SUM="$(printf '%s' "${BD_GIT_DIR}" | cksum | awk '{print $1}')" || BD_WT_SUM=""
  if [ -n "${BD_WT}" ] && [ -n "${BD_WT_SUM}" ]; then
    BD_ID_FILE="${BD_DIR}/agents/${BD_WT}-${BD_WT_SUM}"
    # *** CAP THE COMPOSED NAME, NOT JUST ITS PARTS — THE PIN IS READ BACK AT 64. ***
    # BD_PREFIX caps at 24 and BD_WT at 40, so this composes to at most 65; the .name pin is written
    # UNCAPPED and read back through `bd_sanitize 64`. At 65 chars that made run 1 present a 65-char
    # name and run 2+ a 64-char one for the same worktree — and the doorbell resolves by EXACT display
    # name (src/wake/publisher.ts -> findLiveAgentSessionsByName), so those are two different agents.
    # A pin that changes the value it pins is the failure it exists to prevent. Capping here makes the
    # write and the read agree by construction, and every consumer inherits one value.
    BD_AGENT_NAME="$(printf '%s-%s' "${BD_PREFIX}" "${BD_WT}" | bd_sanitize 64)" || BD_AGENT_NAME=""
  fi
fi
mkdir -p "$(dirname "${BD_ID_FILE}")" 2>/dev/null || true
# *** ONE STATE FILE MUST YIELD ONE NAME. *** The harness half of the name comes from the environment,
# and the environment is not stable: `mcp.sh` answered `claude-wt-a` with CLAUDECODE inherited and
# `mcp-wt-a` without it — same worktree, same id file, ONE server row, two display names. That is
# destructive rather than cosmetic, because the core rewrites `agentName` in place on every tool call
# and the doorbell resolves BY NAME (`findLiveAgentSessionsByName`), so a ticket assigned under one
# harness is invisible to the other on the same lane for the whole session. It is the same defect this
# block's header claims to have removed — "a name that moved would re-point the row the board is
# already addressing" — arriving through a different input.
# So the DERIVED name is pinned next to the id, first writer wins. An EXPLICIT
# `BATONDECK_AGENT_PREFIX` is a deliberate choice and re-pins instead of being overridden.
if [ -n "${BD_AGENT_NAME}" ]; then
  BD_NAME_FILE="${BD_ID_FILE}.name"
  if [ -n "${BATONDECK_AGENT_PREFIX:-}" ]; then
    printf '%s' "${BD_AGENT_NAME}" > "${BD_NAME_FILE}" 2>/dev/null || true
  elif [ -s "${BD_NAME_FILE}" ]; then
    # Re-sanitized on READ: this value becomes an HTTP header, and the file is on disk where anything
    # could have edited it. Newlines included — an unsanitized LF here would split the header.
    BD_PINNED="$(bd_sanitize 64 < "${BD_NAME_FILE}" 2>/dev/null)" || BD_PINNED=""
    [ -n "${BD_PINNED}" ] && BD_AGENT_NAME="${BD_PINNED}"
  else
    printf '%s' "${BD_AGENT_NAME}" > "${BD_NAME_FILE}" 2>/dev/null || true
  fi
fi
# --- END bd-agent-identity -----------------------------------------------------------------------

# Stable per-agent id: persist once and reuse so renames/token-refreshes keep ONE presence row (the
# name floats on top). It is NOT a credential — the bearer identity stays the only security boundary.
# The FILE is per-worktree (see the bd-agent-identity block above), so sibling lanes on one machine
# no longer share a row; a main checkout keeps the legacy single file and does not rotate.
if [ -z "${BATONDECK_AGENT_ID:-}" ]; then
  AID_FILE="${BD_ID_FILE}"
  # `-s`, not `-f`: a ZERO-BYTE file must count as absent and be re-minted, not read as an empty id.
  if [ -s "${AID_FILE}" ]; then
    # *** STRIPPED THE SAME WAY agent-id.sh STRIPS IT. *** `$(cat …)` removes only TRAILING newlines
    # while agent-id.sh removes ALL whitespace, so an id file with leading or internal whitespace made
    # these two scripts present DIFFERENT agent ids from the SAME state file — the contract check 8
    # exists to protect, living outside the diffed block where nothing could observe it. LC_ALL=C
    # because `[:space:]` is locale-dependent (NBSP is kept under C, deleted under UTF-8).
    BATONDECK_AGENT_ID="$(LC_ALL=C tr -d '[:space:]' < "${AID_FILE}")"
  else
    BATONDECK_AGENT_ID="$(uuidgen 2>/dev/null || python3 -c 'import uuid;print(uuid.uuid4())')"
    # TEMP FILE + rename, not create-then-write. `> "${AID_FILE}"` truncates first, so a process killed
    # between open and write left a 0-byte agent-id behind — and plugin/scripts/agent-id.sh could not
    # heal it (its noclobber create refuses to replace an existing file), so that client emitted no
    # agent id ever again. rename(2) is atomic: the file is absent or complete, never empty.
    { printf '%s' "${BATONDECK_AGENT_ID}" > "${AID_FILE}.$$" && mv -f "${AID_FILE}.$$" "${AID_FILE}"; } 2>/dev/null ||
      rm -f "${AID_FILE}.$$" 2>/dev/null || true
  fi
fi

# --- END bd-identity-region --- (scripts/testkit/agent-id-test.sh check 8b extracts to HERE, so the
# id read above is EXECUTED and not merely diffed; everything below needs connection state the testkit
# has no business constructing.)
hdr=(-H "authorization: Bearer ${BATONDECK_TOKEN}" -H "content-type: application/json" -H "accept: application/json, text/event-stream")
# Stamp as agent traffic so the core logs this as an MCP agent session (the human UI BFF is unstamped).
hdr+=(-H "x-batondeck-source: agent")
[ -n "${BATONDECK_AGENT_ID:-}" ] && hdr+=(-H "x-batondeck-agent-id: ${BATONDECK_AGENT_ID}")
# BATONDECK_AGENT wins outright; BD_AGENT_NAME is the per-worktree default and is EMPTY in a main
# checkout, so a caller that sends no name today keeps sending none.
BD_NAME="${BATONDECK_AGENT:-${BD_AGENT_NAME}}"
[ -n "${BD_NAME}" ] && hdr+=(-H "x-batondeck-agent: ${BD_NAME}")

# Cached session + affinity-cookie jar, keyed by core URL + scope. Concurrent callers share them; a
# stale entry is healed by the retry path below. MCP_SESSION_SCOPE isolates a caller onto its own
# cached session; nothing sets it since T-177 deleted watch.sh, its only setter.
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
case " next_task rank_tasks search_tasks get_task get_board get_project get_transitions get_task_context list_tasks list_boards list_projects list_subtasks list_attachments list_comments list_follow_ups list_runs list_notifications read_memory get_skill_stats list_agent_sessions " in
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

#!/usr/bin/env bash
# BatonDeck plugin — the agent's STABLE identity, generated once and presented on every connect.
#
#   agent-id.sh             print the agent id (bare string)
#   agent-id.sh --path      print the state file this checkout resolves to (rotation needs it)
#   agent-id.sh --name      print the display name this checkout is addressed by (use as `assignee`)
#   agent-id.sh --migrate   report this checkout's identity before/after the per-worktree change
#   agent-id.sh --headers [project-dir]
#                           print the MCP connection headers as JSON  <- `headersHelper` in .mcp.json
#                           `project-dir` names the checkout whose worktree the id is keyed on;
#                           omitted, it falls back to $CLAUDE_PROJECT_DIR and then to the cwd.
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
# CONTRACT SHARED WITH scripts/mcp.sh: both resolve the SAME state file, so the curl path and the MCP
# path present the same agent. Since that path is now per-worktree it is no longer a one-line constant
# two files could plausibly keep in step by hand, so the logic lives in the `bd-agent-identity` block
# below and is BYTE-IDENTICAL in both scripts — scripts/testkit/agent-id-test.sh diffs them.
#
# No `set -e`: a headersHelper that dies before printing costs the user their agent id. Every step
# below is individually tolerant and the script always reaches its final print.
set -u

dir="${BATONDECK_STATE_DIR:-${HOME:-/tmp}/.batondeck}"
BD_DIR="${dir}"
# The project dir is the first NON-FLAG argument, so it reads the same after `--headers`/`--path` as
# without them. Positional `$2` looked equivalent and was not: `agent-id.sh <dir>` put it in $1.
# This script is the PLUGIN's headersHelper, so it only ever runs under Claude Code — the prefix is
# known, not detected. `BATONDECK_AGENT_PREFIX` still wins for anyone reusing the script elsewhere.
BD_PREFIX="${BATONDECK_AGENT_PREFIX:-claude}"
BD_PROJ=""
for _a in "$@"; do case "${_a}" in --*) ;; *) BD_PROJ="${_a}"; break ;; esac; done
BD_PROJ_EXPLICIT="${BD_PROJ}"
unset _a
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
    BD_AGENT_NAME="${BD_PREFIX}-${BD_WT}"
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
file="${BD_ID_FILE}"

id="${BATONDECK_AGENT_ID:-}"

if [ -z "${id}" ]; then
  mkdir -p "${dir}" 2>/dev/null
  id="$(cat "${file}" 2>/dev/null)" || id=""
  # Stripped HERE, before the emptiness test below — not only at the end. A ZERO-BYTE or
  # whitespace-only file yields no usable id, and it has to read as ABSENT so the mint path heals it.
  # LC_ALL=C: `tr -d '[:space:]'` is LOCALE-SENSITIVE. Measured: a non-breaking space is KEPT under C
  # and DELETED under en_US.UTF-8, so one state file yielded two different agent ids depending on the
  # inherited LANG — the same class as the sanitizers above, on the id rather than the name.
  id="$(printf '%s' "${id}" | LC_ALL=C tr -d '[:space:]')"
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
id="$(printf '%s' "${id}" | LC_ALL=C tr -d '[:space:]')"

# DELIBERATE: if the id could not be persisted (read-only HOME, no uuidgen), emit NOTHING rather than a
# fresh random id. An unpersisted id would be new on every connect — forking presence and orphaning the
# previous wake subscription to its TTL every session, which is worse than today's collapsed-but-stable
# `id:<identityId>` fallback. Silence degrades to exactly today's behaviour.

# `--path` exists because the documented rotation step used to be a literal `rm ~/.batondeck/agent-id`
# and the path is now COMPUTED. An instruction naming a file the script no longer uses is how a user
# deletes the wrong thing and concludes rotation does not work.
if [ "${1:-}" = "--migrate" ]; then
  # Same requirement as `--path`, and for the same reason: this prints a per-CHECKOUT verdict, and
  # defaulting to the cwd means answering confidently about a checkout the caller never named. A false
  # "GRANDFATHERED: no action needed" is worse than no answer, because the user stops looking.
  if [ -z "${BD_PROJ_EXPLICIT:-}" ]; then # guard:migrate
    echo "agent-id.sh --migrate needs the checkout: agent-id.sh --migrate <dir>  (e.g. --migrate \"\$PWD\")" >&2
    exit 2
  fi
  # Report what this checkout's identity WAS and what it now IS, for someone upgrading across the
  # per-worktree change. There is deliberately NO state rewriting here: the legacy file keeps working
  # and the main checkout keeps using it, so nothing is orphaned and there is nothing to move. What
  # DOES need a human decision is board data — work assigned before the upgrade was addressed to the
  # one shared agent, and a worktree lane now answers to a different name. Printing the two names is
  # the whole migration; re-routing is a board operation, not a file operation.
  _legacy="${BD_DIR}/agent-id"
  echo "checkout      : ${BD_PROJ}"
  if [ -s "${_legacy}" ]; then
    echo "legacy id     : $(cat "${_legacy}" 2>/dev/null)  (${_legacy})"
  else
    echo "legacy id     : <none> — nothing to migrate from"
  fi
  echo "this id       : ${id}"
  echo "this name     : ${BATONDECK_AGENT:-${BD_AGENT_NAME:-<none — the server falls back to your MCP client name>}}"
  if [ "${BD_ID_FILE}" = "${_legacy}" ]; then
    echo
    echo "GRANDFATHERED: this checkout still uses the legacy file, so its presence row, its wake"
    echo "subscription and anything assigned to it are unchanged. No action needed."
  else
    echo
    echo "NEW IDENTITY: this worktree used to share the legacy id and now has its own."
    echo "Work assigned BEFORE the upgrade was addressed to the shared agent, so it will not appear"
    echo "under this lane's new name. Find it and re-route it once:"
    echo "  list_tasks   { projectId, boardId, assignee: \"<the old shared name>\" }"
    echo "  update_task  { projectId, taskId, version, patch: { assignee: \"${BATONDECK_AGENT:-${BD_AGENT_NAME}}\" } }"
    echo "The old shared name is whatever the Agents page showed before today — with no"
    echo "x-batondeck-agent header the server recorded your MCP client's own name (or \"agent\")."
  fi
  exit 0
fi

if [ "${1:-}" = "--path" ]; then
  # *** AN EXPLICIT CHECKOUT IS REQUIRED, and that is a safety property, not pedantry. *** This
  # prints a path the documented rotation step passes straight to `rm`. Defaulting to the cwd
  # means running that command from anywhere outside the worktree names the MAIN checkout's id
  # and deletes it — rotating an identity the user never meant to touch, which is indistinguishable
  # from rotation "not working". `--name` keeps the cwd default: it only prints a name.
  if [ -z "${BD_PROJ_EXPLICIT:-}" ]; then # guard:path
    echo "agent-id.sh --path needs the checkout: agent-id.sh --path <dir>  (e.g. --path \"\$PWD\")" >&2
    exit 2
  fi
  printf '%s\n' "${BD_ID_FILE}"
elif [ "${1:-}" = "--name" ]; then
  # The display name this checkout is addressed by. An agent is instructed to use its own name as
  # `assignee`, and that name is now DERIVED rather than typed by a human — so without a way to read
  # it back, the agent cannot name itself. Empty in a main checkout, which is correct: that is
  # precisely the case where no default name is sent.
  printf '%s\n' "${BATONDECK_AGENT:-${BD_AGENT_NAME}}"
elif [ "${1:-}" = "--headers" ]; then
  # A blank/absent header is the legitimate "no id" case server-side, so an empty object is safe.
  # Claude Code tolerates a helper that fails, prints nothing, or prints garbage: it connects without
  # the extra headers (verified against 2.1.220). So the worst case here is today's behaviour.
  # BATONDECK_AGENT still wins outright; BD_AGENT_NAME is the per-worktree default and is EMPTY in a
# main checkout, so a client that sends no name today keeps sending none.
python3 - "${id}" "${BATONDECK_AGENT:-${BD_AGENT_NAME}}" <<'PY' 2>/dev/null || printf '{}\n'
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

# Rotate (the only way back from a sticky `disconnect_agent`) — print the path first, because in a
# linked worktree it is `~/.batondeck/agents/<worktree>-<sum>`, not the legacy single file. The
# checkout argument is REQUIRED (see --path above), so a one-liner without it deletes nothing:
#     rm "$(bash agent-id.sh --path "$PWD")"   then restart the MCP client
# The pinned display name lives beside it and should go too, or the new id inherits the old name:
#     rm "$(bash agent-id.sh --path "$PWD")".name
# The next connect mints a new id; the old one stays disconnected, which is the point.

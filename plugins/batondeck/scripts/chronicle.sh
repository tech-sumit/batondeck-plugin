#!/usr/bin/env bash
# BatonDeck plugin — the deterministic bits of the Chronicle sweep (`/batondeck:chronicle`).
#
#   chronicle.sh forge                        what forge evidence THIS MACHINE can reach (never fails)
#   chronicle.sh sweep  < in.json > out.json  pipe a board window through scripts/chronicle/sweep.py
#   chronicle.sh cursor get <projectId>       read  chronicle.cursor from project memory  (HEADLESS ONLY)
#   chronicle.sh cursor set <projectId> <c>   write chronicle.cursor to project memory    (HEADLESS ONLY)
#
# AUTH, AND WHY ONE OF THESE REFUSES INSTEAD OF WORKING.
# `cursor` shells out to mcp.sh, which requires BATONDECK_TOKEN. A plugin / browser-OAuth session does
# NOT have one in Bash — that token lives inside the MCP client and is invisible to this process. That
# is CONTRIBUTING rule 8 and the incident that wrote it (the worker loop told OAuth users to run a
# script that cannot authenticate; the watch died instantly and the agent waited forever). So on the
# OAuth path the agent calls `recall_memory` / `write_memory` ITSELF, in session, and this subcommand
# refuses with that instruction rather than dying obscurely two layers down.
# `forge` and `sweep` need no auth at all and work identically on both paths.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

usage() { echo "usage: chronicle.sh forge | sweep | cursor get|set <projectId> [cursor]" >&2; exit 2; }

case "${1:-}" in
forge)
  # §8.4: forge enrichment is BEST-EFFORT and must never block a sweep, so this ALWAYS exits 0 and the
  # worst answer is `none`. It reports only what a SHELL can see. A GitHub MCP server is visible in the
  # agent's own tool list, not to this process, so the skill checks that half itself and combines them.
  if ! command -v gh >/dev/null 2>&1; then
    echo none
  elif gh auth status >/dev/null 2>&1; then
    echo gh
  else
    # Present but not signed in: `gh api` would 401 on every review thread. Reported apart from `gh`
    # so the coverage line can say WHY it degraded — "no forge credentials" is the §6.6 wording, and a
    # page claiming an absence it never checked is the one failure Chronicle cannot afford.
    echo gh-unauth
  fi
  ;;

sweep)
  # The deterministic half lives in the DOCUMENTED repo (`scripts/chronicle/sweep.py`), not in the
  # plugin: it is owned and tested there (`scripts/chronicle/sweep-test.py`), and shipping a second
  # copy here would be a generated file with no `*:check` — rule 2's definition of future rot.
  for c in "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/scripts/chronicle/sweep.py" \
           "./scripts/chronicle/sweep.py"; do
    [ -f "${c}" ] && exec python3 "${c}"
  done
  cat >&2 <<'MSG'
ERROR: scripts/chronicle/sweep.py not found (looked from the git root and from the current directory).

That file is the pure function this wraps — board window on stdin, ingest_chronicle_page payloads on
stdout — and it ships in the repo being chronicled, not in the plugin. Either you are not standing in
that repo, or this checkout predates it.

Refusing rather than composing records some other way: this wrapper exists so the text a reader can
check comes from ONE deterministic generator. There is no fallback that would still be that.
MSG
  exit 2
  ;;

cursor)
  sub="${2:-}"; pid="${3:-}"
  [ -n "${sub}" ] && [ -n "${pid}" ] || usage
  [ -n "${BATONDECK_TOKEN:-}" ] || {
    cat >&2 <<'MSG'
REFUSING: no BATONDECK_TOKEN, so the cursor cannot be read or written from a shell.

You are almost certainly on the plugin / browser-OAuth path, where that is expected and not a fault:
the MCP access token lives inside your MCP client and Bash cannot see it. Call the tools yourself,
in session — they are the same two calls this would have made:

  read   recall_memory { projectId, scope: "project", key: "chronicle.cursor" }   -> entries[0].value
  write  write_memory  { projectId, scope: "project", key: "chronicle.cursor", value: "<ts|id>" }

This subcommand serves the headless path only (a real BATONDECK_TOKEN from a browser sign-in that
already happened). There is no headless mint: the authorization server advertises only
authorization_code + refresh_token.
MSG
    exit 2
  }
  case "${sub}" in
    get)
      "${here}/mcp.sh" recall_memory \
        "$(python3 -c 'import json,sys; print(json.dumps({"projectId":sys.argv[1],"scope":"project","key":"chronicle.cursor"}))' "${pid}")" \
        | python3 -c 'import json,sys; e=json.load(sys.stdin).get("entries") or []; print(e[0]["value"] if e else "")'
      ;;
    set)
      cur="${4:-}"; [ -n "${cur}" ] || usage
      "${here}/mcp.sh" write_memory \
        "$(python3 -c 'import json,sys; print(json.dumps({"projectId":sys.argv[1],"scope":"project","key":"chronicle.cursor","value":sys.argv[2]}))' "${pid}" "${cur}")" \
        >/dev/null
      echo "chronicle.cursor=${cur}"
      ;;
    *) usage ;;
  esac
  ;;

*) usage ;;
esac

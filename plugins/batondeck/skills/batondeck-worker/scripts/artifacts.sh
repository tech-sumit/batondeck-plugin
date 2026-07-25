#!/usr/bin/env bash
# Print the `artifacts` array for the CURRENT checkout, ready to paste into add_artifact /
# complete_task. Reads only the local VCS — no BatonDeck auth, no network — so it works in every auth
# mode (browser OAuth, service account, dev), which the token-bearing scripts here do not.
#
#   bash scripts/artifacts.sh                       # branch + head commit (+ PR if gh/glab can tell us)
#   bash scripts/artifacts.sh https://…/pull/418    # …with the review URL you already know
#
# Forge-agnostic by construction: the remote is normalized to `host/path` from whatever form it takes
# (scp-style `git@host:path`, ssh://, https://, with or without `.git`), and only the *browse* URL
# shape is per-forge — with a fallback that records the bare ref. A repo with NO remote still emits
# commit + branch refs, so the ticket is auditable without a forge at all. Mercurial is handled too.
set -euo pipefail

review_url="${1:-}"

esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
# Emit one {…} entry; skips itself when both url and ref are empty.
entry() { # entry <kind> <url> <ref> [repo]
  [ -n "$2$3" ] || return 0
  printf '%s{"kind":"%s"' "${sep}" "$1"
  if [ -n "$2" ]; then printf ',"url":"%s"' "$(esc "$2")"; fi
  if [ -n "$3" ]; then printf ',"ref":"%s"' "$(esc "$3")"; fi
  if [ -n "${4:-}" ]; then printf ',"repo":"%s"' "$(esc "$4")"; fi
  printf '}'
  sep=','
}
sep=''

if [ -d .hg ] || hg root >/dev/null 2>&1; then
  branch="$(hg branch 2>/dev/null || true)"
  sha="$(hg id -i 2>/dev/null || true)"
  remote="$(hg paths default 2>/dev/null || true)"
else
  git rev-parse --git-dir >/dev/null 2>&1 || { echo '[]'; exit 0; }
  branch="$(git branch --show-current 2>/dev/null || true)"
  sha="$(git rev-parse --short HEAD 2>/dev/null || true)"
  # First remote of `git remote -v` — `origin` when it exists, else whatever this clone does have.
  remote="$(git remote get-url origin 2>/dev/null || git remote -v 2>/dev/null | awk 'NR==1{print $2}')"
fi

# ---- normalize the remote to `host/path` (no scheme, no user, no .git) --------------------------
repo=''
if [ -n "${remote:-}" ]; then
  repo="${remote%.git}"
  repo="${repo#*://}"          # https://, ssh://, git://, hg+https:// …
  repo="${repo#*@}"            # user@ / git@
  # Order matters: drop an ssh PORT (`host:7999/path`) before turning a scp-style colon
  # (`host:team/app`) into a slash, or the port becomes a path segment.
  repo="$(printf '%s' "${repo}" | sed -e 's#:[0-9]\{1,5\}/#/#' -e 's#:#/#' -e 's#//*#/#g')"
fi
host="${repo%%/*}"

# ---- per-forge browse-URL shape, with an honest fallback ----------------------------------------
# The shapes below are the forge's, not a guess: anything unrecognized records the ref WITHOUT a url
# rather than fabricating a link that 404s.
branch_url=''; commit_url=''
case "${host}" in
  github.com|github.*|*.github.*|ghe.*)  branch_url="https://${repo}/tree";       commit_url="https://${repo}/commit" ;;
  gitlab.com|gitlab.*|*.gitlab.*)        branch_url="https://${repo}/-/tree";     commit_url="https://${repo}/-/commit" ;;
  bitbucket.org|bitbucket.*)             branch_url="https://${repo}/src";        commit_url="https://${repo}/commits" ;;
  *gerrit*|*review*)                     branch_url="";                           commit_url="" ;;  # a Gerrit change has its own URL — pass it as $1
  *)                                     branch_url="";                           commit_url="" ;;
esac

# ---- the review URL: given, or asked of whichever forge CLI is installed ------------------------
if [ -z "${review_url}" ]; then
  review_url="$(gh pr view --json url --jq .url 2>/dev/null || true)"
fi
if [ -z "${review_url}" ]; then
  review_url="$(glab mr view -F json 2>/dev/null | sed -n 's/.*"web_url":"\([^"]*\)".*/\1/p' | head -1 || true)"
fi

printf '['
entry pr "${review_url}" '' "${repo}"
entry branch "${branch:+${branch_url:+${branch_url}/${branch}}}" "${branch}" "${repo}"
entry commit "${sha:+${commit_url:+${commit_url}/${sha}}}" "${sha}" "${repo}"
printf ']\n'

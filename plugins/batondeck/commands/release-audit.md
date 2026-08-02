---
description: Audit main against the last release — what's changing, what's unsafe, and tickets for the gaps.
---

Run a release-readiness audit and file what it finds onto a BatonDeck board.

Delegate this to the **release-auditor** agent — it carries the full procedure (resolve the delta from
the last release by merge-base, review it for release risk, run the repository's own gate, file the
findings, print a GO / GO WITH FIXES / NO-GO verdict). Do not re-derive the steps here.

$ARGUMENTS may carry the target `projectId` / `boardId` to file onto, and optionally an explicit base
ref to diff from. Pass them through verbatim. If no board is given, the agent discovers one with
`list_projects` → `list_boards` and asks when the choice is ambiguous.

Nothing here fixes code. The audit reads, runs checks, and files tickets; fixing happens from those
tickets like any other work on the board.

Arguments: $ARGUMENTS

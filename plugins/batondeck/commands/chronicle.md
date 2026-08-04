---
description: Sweep the board's finished tickets into Chronicle decision records — why it was built, how, and what review changed.
---

Run a **Chronicle sweep** over a BatonDeck board. Finished tickets already carry the evidence — the
description, the deliverable, the `DONE / NEXT / REJECTED / UNCERTAIN` checkpoints, the PR and branch
artifacts — but it is per-ticket and write-only, and nobody reads 160 tickets to answer "why does auth
work this way?". The sweep lays that evidence out as decision records and cites every paragraph back
to the ticket it came from.

> **PRECONDITION: run this from a checkout of the BatonDeck repo.** The deterministic half of the
> sweep is `scripts/chronicle/sweep.py`, which lives in that repo and is deliberately NOT shipped in
> the plugin — it is owned and tested where it lives, and a second copy would drift from it. From any
> other repo, step 4 stops with a message naming the path it could not find. It fails cleanly rather
> than producing a partial record, but it does fail, so check before you start rather than after
> gathering evidence for 160 tickets.

Inputs: $ARGUMENTS — optionally the project/board. Missing → discover with `list_projects` →
`list_boards`. Manual by design: this is not scheduled, and it runs as **you**, in this session,
because there is no headless path to the core.

The sweep (full procedure in the batondeck-chronicle skill — follow it, this is the shape):

1. **Read the cursor.** `recall_memory { projectId, scope: "project", key: "chronicle.cursor" }` →
   `entries[0].value`, or genesis if empty. It lives in project memory, not in a file, so two clones
   cannot fork it and chronicle the same tickets twice. **Read and write it with these tool calls
   yourself** — the shell helper needs `BATONDECK_TOKEN`, which a browser-OAuth session does not have
   in Bash.
2. **Take the window — one call is one batch.**
   `wait_for_updates { projectId, boardId, sinceCursor, timeoutSec: 1, limit: 20 }`, keeping
   `task.completed` / `task.reopened` / `task.requeued` / `task.moved` with `data.to: "DONE"` (a
   reopen after DONE is a supersession signal, not noise; the moved row is how an approval is seen at
   all — `complete_task` fires `task.completed` at REVIEW entry and the REVIEW→DONE approval emits
   only `task.moved`, so without it a ticket in REVIEW at anchor time is stranded forever). `limit` is the batch cap because the response carries **one cursor for the whole call**
   — process this call's tickets in full, write its cursor, then decide whether to call again; there is
   no cursor for "the 20th event" to write instead. `truncated: true` means you **missed** events
   BEHIND this window (your cursor was older than the five-minute lookback), not that more remain —
   sweep the batch and advance anyway (the floor is computed from request arrival, so holding the
   cursor recovers nothing and re-derives the same window forever), then **report the gap**. No cursor
   yet → `list_tasks { status: "DONE" }` for the backfill; the feed cannot serve history. That listing
   is also how you deliberately close a gap, and it is all-or-nothing: cap it and you write **no**
   cursor, because its anchor says "now". Nothing new is a legitimate no-op — stop and say so.
3. **Pull the evidence.** Two calls per ticket, and it has to be two: `get_task { projectId, taskId }`
   for `title`/`description`/`deliverable`/`artifacts`, and
   `get_task_context { projectId, taskId, include: ["items"] }` for the checkpoints. The context tool
   returns **no description and no title**. Its checkpoints arrive under `items` — **pass that key
   through unrenamed.** An earlier version of this page said to rename it to `contextItems`, because
   the script read that key; the script was the thing that was wrong and now reads `items` directly.
   It refuses `contextItems` outright rather than quietly reporting a ticket as carrying no rejected
   alternatives when it plainly does. **Resolve cross-window mentions yourself:** the script cites a
   `T-\d+` only where it knows the ticket's board, so a "Supersedes T-42" whose target is outside the
   window goes uncited unless you look it up (`get_task { projectId, taskId }` — ids are unique per
   project) and pass `knownTasks: { "T-42": "<boardId>" }`. Omit whatever 404s; it will not invent one.
4. **Compose.** `bash "${CLAUDE_PLUGIN_ROOT}/scripts/chronicle.sh" sweep < window.json > pages.json`.
   That wraps the repo's deterministic sweep script: the same evidence always produces the same text,
   which is what makes a record checkable. **Do not write record prose yourself.**
5. **Enrich, best-effort.** `bash "${CLAUDE_PLUGIN_ROOT}/scripts/chronicle.sh" forge` reports whether
   this machine has `gh`; a GitHub MCP counts too and only you can see that. Found nothing → degrade
   to nothing and carry on. Forge review threads are enrichment on top of the board evidence, never a
   precondition, and every record already declares which of the two it had.
6. **Ingest.** `ingest_chronicle_page { projectId, kind, slug, title, blocks }` per page — add the
   `projectId`, which the script does not carry. Re-ingest merges rather than overwrites: human edits
   survive, and anything changed on both sides comes back as a conflict for a human to land. Report
   conflicts; do not resolve them.
7. **Advance the cursor last.** `write_memory { projectId, scope: "project", key: "chronicle.cursor",
   value }` — **the cursor of the batch you just finished, only after every page in it ingested.** A
   sweep that dies mid-flight leaves the cursor at the last completed batch and is re-derived next
   run; ingest is idempotent per slug (`adr/<task-id>`), so the failure mode is a repeated sweep,
   never a skipped ticket. Capped a genesis backfill? Write nothing and say how many remain.

Report one line per record (ticket, slug, blocks, coverage), the cursor you wrote or the reason you
did not, any conflicts, and whether you capped the batch. This half ends at the hosted surface — it
does not write `docs/chronicle/` files or raise a docs PR.

Follow the batondeck-chronicle skill for the full procedure. Project/board: $ARGUMENTS

---
description: Sweep the board's finished tickets into Chronicle decision records — why it was built, how, and what review changed.
---

Run a **Chronicle sweep** over a BatonDeck board. Finished tickets already carry the evidence — the
description, the deliverable, the `DONE / NEXT / REJECTED / UNCERTAIN` checkpoints, the PR and branch
artifacts — but it is per-ticket and write-only, and nobody reads 160 tickets to answer "why does auth
work this way?". The sweep lays that evidence out as decision records and cites every paragraph back
to the ticket it came from.

> **PRECONDITION: run this from a checkout of the BatonDeck repo.** The deterministic half of the
> sweep — `scripts/chronicle/sweep.py` and the repo-tier emitter `scripts/chronicle/emit.py` — lives
> in that repo and is deliberately NOT shipped in the plugin: it is owned and tested where it lives,
> and a second copy would drift from it. From any other repo, step 4 stops with a message naming the
> path it could not find. It fails cleanly rather than producing a partial record, but it does fail,
> so check before you start rather than after gathering evidence for 160 tickets.

Inputs: $ARGUMENTS — optionally the project/board. Missing → discover with `list_projects` →
`list_boards`. Manual by design: this is not scheduled, and it runs as **you**, in this session,
because there is no headless path to the core.

The sweep (full procedure in the batondeck-chronicle skill — follow it, this is the shape):

1. **Read the cursor.** `recall_memory { projectId, scope: "project", key: "chronicle.cursor" }` →
   `entries[0].value`, or genesis if empty. It lives in project memory, not in a file, so two clones
   cannot fork it and chronicle the same tickets twice. **Read and write it with these tool calls
   yourself** — the shell helper needs `BATONDECK_TOKEN`, which a browser-OAuth session does not have
   in Bash.
2. **Take the window — one query, by ticket, not by event.**
   `list_tasks { projectId, boardId, status: "DONE", updatedSince: "<cursor>", limit: 200 }`, paging
   with the returned `nextCursor`.

   **This replaced a cursor-paged event feed (`wait_for_updates`) that T-177 retired, and the new <!-- retired-tool-ok: the replaced mechanism, named so a stale cursor is recognisable -->
   shape is strictly better for this job.** "Which tickets finished since my last sweep" is a question
   about TASKS; asking the task collection answers it directly. Three traps the event version carried
   simply do not exist here:
   - no five-minute lookback clamp, so an old cursor is not silently truncated — the whole point of
     the `truncated: true` warning that sweep had to reason about;
   - no "one cursor for the whole call" hazard, because paging is by `nextCursor` over the tickets you
     actually processed;
   - no REVIEW-entry-versus-approval split. `complete_task` fired `task.completed` at REVIEW entry
     while the REVIEW→DONE approval emitted only `task.moved`, so a ticket sitting in REVIEW at anchor
     time was stranded forever. A ticket that is DONE is DONE, whichever tool got it there.

   **The cursor is an ISO instant now, not an opaque `ts|id` token.** Write the newest `updatedAt` you
   actually processed. The filter is INCLUSIVE at the boundary, so re-reading your own instant costs
   one duplicate ticket (which merges to a no-op) rather than losing one.

   A reopen after DONE is still a supersession signal — it shows up as the ticket's `updatedAt` moving
   while its status is not DONE, so a swept ticket that has since left DONE is worth a second look.
   Nothing new is a legitimate no-op — stop and say so.
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
4. **Compose and emit.** `python3 scripts/chronicle/emit.py < window.json > pages.json` — the same
   deterministic composition as the sweep, PLUS the repo tier: `docs/chronicle/adr/NNNN-<slug>.md`
   per new record (append-only, ids allocated max(existing)+1 from the filesystem), `superseded_by`
   stamped where the payload declares `supersedes`, topics/index mechanical regions regenerated
   (narrative and registry untouched), and the ingest payloads on stdout with `sourcePath` filled.
   Already-chronicled tickets (triple in some record's `tasks:`) are skipped, so re-runs mint no
   duplicates. Verify with `python3 scripts/chronicle/check.py` before anything moves. The same
   evidence always produces the same text — **do not write record prose yourself.** The hosted slug
   stays `adr/<task-id>`; ADR-NNNN names the FILE, never the page (T-300).
5. **Enrich, best-effort.** `bash "${CLAUDE_PLUGIN_ROOT}/scripts/chronicle.sh" forge` reports whether
   this machine has `gh`; a GitHub MCP counts too and only you can see that. Found nothing → degrade
   to nothing and carry on. Forge review threads are enrichment on top of the board evidence, never a
   precondition, and every record already declares which of the two it had.
6. **Ingest.** `ingest_chronicle_page { projectId, kind, slug, title, sourcePath, blocks }` per page —
   add the `projectId`, which the script does not carry. Re-ingest merges rather than overwrites:
   human edits survive, and anything changed on both sides comes back as a conflict for a human to
   land. Report conflicts; do not resolve them.
7. **Raise ONE docs PR for the batch.** The emitter touched no git — the procedure owns it:
   `git checkout -b docs/chronicle-sweep-$(date +%F)`, stage `docs/chronicle` ONLY, commit, push,
   `gh pr create --fill --base main`. A later batch in the same session commits onto the same raised
   PR. A duplicate-id refusal from the gate means another sweep's PR merged first: reset onto fresh
   `origin/main`, re-run the emitter, commit again.
8. **Advance the cursor last.** `write_memory { projectId, scope: "project", key: "chronicle.cursor",
   value }` — **the cursor of the batch you just finished, only after every page in it ingested AND
   the docs PR is raised** (changed by T-300 from advance-after-ingest; §8.3 step 9). A sweep that
   dies mid-flight leaves the cursor at the last completed batch and is re-derived next run; ingest
   is idempotent per slug (`adr/<task-id>`) and the emitter skips committed triples, so the failure
   mode is a repeated sweep, never a skipped ticket. Capped a genesis backfill? Write nothing and say
   how many remain.

Report one line per record (ticket, slug, ADR file, blocks, coverage), the docs PR url or why there
is none, the cursor you wrote or the reason you did not, any conflicts, and whether you capped the
batch.

Follow the batondeck-chronicle skill for the full procedure. Project/board: $ARGUMENTS

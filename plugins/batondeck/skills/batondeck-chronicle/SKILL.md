---
name: batondeck-chronicle
description: Sweep a BatonDeck board's finished tickets into Chronicle decision records. Reads a durable project-memory cursor, takes the window of task.completed / task.reopened / task.requeued events since it, pulls each ticket's composed context over MCP, pipes the batch through the repo's deterministic sweep script, ingests the resulting pages with ingest_chronicle_page, and advances the cursor only after the ingest succeeds — so a sweep that dies mid-flight is re-derived on the next run instead of losing tickets. Forge (GitHub) review threads are best-effort enrichment that never blocks a sweep, and every record declares which evidence it actually had. Invoked by the plugin's /batondeck:chronicle command.
---

# BatonDeck Chronicle

You turn finished tickets into **decision records**: why a thing was built, how it was actually
implemented, and what review changed. The evidence is already on the board — descriptions,
deliverables, `DONE / NEXT / REJECTED / UNCERTAIN` checkpoints, artifacts. Nobody reads 160 tickets to
find it, so the sweep lays it out in ADR shape and cites every paragraph back to the ticket it came
from.

**You extract and lay out. You never invent a sentence.** The prose in a record comes from ticket
fields verbatim; the sweep script does the composing, deterministically, so a re-run over the same
evidence produces the same text and a reader can check any line against its citation. If the evidence
is not there, the record says so (`coverage: partial`) — claiming an absence you did not verify, or a
presence you did not read, is the one failure this feature cannot survive.

## The auth mode this assumes

**A signed-in MCP session — the plugin's browser OAuth, which is the normal case.** The sweep is an
agent procedure, not a CI job: the authorization server advertises only `authorization_code` +
`refresh_token`, so every token the core accepts has passed through a browser at least once. There is
no headless mint, and there is no scheduled sweep. You are the runtime.

Two consequences, both of which have bitten this repo before:

- **The cursor is read and written by YOU, with MCP tool calls** — `recall_memory` / `write_memory`.
  Do **not** reach for a shell helper to do it. `"${CLAUDE_PLUGIN_ROOT}/scripts/chronicle.sh" cursor …`
  shells out to `mcp.sh`, which needs `BATONDECK_TOKEN`, and an OAuth session has none in Bash (the
  token lives inside the MCP client, invisible to a subprocess). That subcommand exists for the
  headless path only and refuses loudly here rather than dying two layers down.
- **The two shell steps that DO work on both paths** are `chronicle.sh forge` and `chronicle.sh sweep`.
  Neither touches the network.

## The sweep

### 1. Read the cursor

```
recall_memory { projectId, scope: "project", key: "chronicle.cursor" }
```

The value is `entries[0].value` — an opaque `ts|id` board cursor — or **genesis** when `entries` is
empty. It lives in project memory rather than in a file on purpose: a repo-local cursor forks between
clones, and two machines would then chronicle the same tickets twice.

### 2. Take the window

**Incremental (you have a cursor).** Drain the event feed from it:

```
wait_for_updates { projectId, boardId, sinceCursor: "<cursor>", timeoutSec: 1, limit: 200 }
```

Keep the events whose `type` is `task.completed`, `task.reopened` or `task.requeued`, and collect
their `taskId`s. A reopen *after* DONE is itself a supersession signal, which is why it is in the set
and not filtered out as noise. While the response says `truncated: true`, call again with the
`cursor` it returned — a large backlog drains over successive calls. **Hold the last `cursor` you
saw; that is what you will write back at the end, and only at the end.** `timeoutSec: 1` keeps a
no-op sweep to about a second: with nothing new, this returns `{ events: [] }` and the cursor
unchanged, and you stop here having written nothing.

**Genesis (no cursor yet).** The event feed cannot serve a backfill — called without `sinceCursor` it
returns the cursor as of *now* and no history. So take the finished tickets instead:

```
list_tasks { projectId, boardId, status: "DONE", limit: 200 }
```

Page with the returned `cursor` if there are more. Then get an anchor for next time by calling
`wait_for_updates { projectId, boardId, timeoutSec: 1 }` with no `sinceCursor` and keeping its
`cursor`. Note what genesis does not see: `task.reopened` / `task.requeued` are event-only signals, so
a first sweep chronicles DONE tickets and nothing else.

**Cap the batch.** A window of more than ~20 tickets is a token problem, not a correctness one: sweep
the oldest 20, ingest them, advance the cursor to the last event you actually processed, and say in
your report that more remain. Sweeping is resumable by design; a half-finished sweep that advanced
the cursor past unswept tickets is not.

### 3. Pull each ticket's evidence

**Two calls per ticket, and it has to be two.** Neither tool alone carries what the script reads —
this is measured against the live board, not inferred from the tool descriptions:

```
get_task         { projectId, taskId }                       -> task.{id, title, description, deliverable, artifacts}
get_task_context { projectId, taskId, include: ["items"] }   -> items[]  (each with a `body`)
```

`get_task_context` returns **no `description`, no `title` and no `id`** — its `deliverable` and
`artifacts` are there, but the ticket's own prose is not, and that prose is most of a record.

**Do NOT rename anything.** Pass `items` through exactly as the tool returns it. The shape the script
expects, exactly:

```json
{ "projectId": "P-…", "boardId": "B-…",
  "tasks": [ { "id": "T-162", "title": "…", "description": "…", "deliverable": "…",
               "items": [ { "body": "…" } ],
               "artifacts": [ { "kind": "pr", "url": "…" } ] } ] }
```

This page used to instruct a rename to `contextItems`, because the script read that key and a payload
carrying `items` produced a record whose coverage line said *"Not found on the ticket: rejected
alternatives"* about a ticket that plainly carried them — asserting an absence nobody ever checked,
which is the one failure this feature cannot survive. **The script was the thing that was wrong**, and
it has been fixed to read the producer's own key; the workaround is now the bug. `contextItems` is the
Firestore subcollection name (`src/data/firestore-store.ts`) and never crosses the wire.

Feeding `contextItems` today does not silently misreport — `sweep.py` refuses it outright with a
`ValueError` naming both keys. That refusal is deliberate: an input shape we do not understand must be
loud, because the failure it replaces was a confident false statement in a published record.

On the genesis path `list_tasks` has already returned `title`, `description` and `deliverable` for
every ticket, so `get_task` is redundant there and only `get_task_context` is needed per ticket. Take
that shortcut if you like; the uniform two-call recipe is correct on both paths.

A ticket with neither a description nor a deliverable carries no evidence and the script drops it —
that is the mechanism behind "a completed non-decision ticket produces no record", so do not paper
over an empty ticket by writing prose for it.

### 4. Compose (deterministic — do not do this yourself)

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/chronicle.sh" sweep < window.json > pages.json
```

Out comes one `ingest_chronicle_page` payload per ticket: `kind`, `slug`, `title`, `blocks[]`, each
block carrying its citations (the full `projectId/boardId/taskId` triple — never a bare `T-52`, which
is not unique even within one project) and an `origin.blockHash`.

**Write nothing into those blocks by hand.** Their ids are section-scoped (`context/2`,
`decision/1`) so that the server-side merge can tell an edited block from a moved one; hand-authored
text that arrives through this path would be recorded as `derived` and would inherit a citation's
authority without having been derived from it.

### 5. Enrich — best-effort, never blocking

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/chronicle.sh" forge
```

Prints `gh`, `gh-unauth`, or `none`, and always exits 0. That covers the shell half; the other half is
your own tool list — a GitHub MCP server is visible to you and not to a subprocess, so check for one
before concluding `none`.

- `gh` or a GitHub MCP → you may fetch review threads for a `pr` artifact and fold them into the
  record. Cap it: one fetch per PR, and skip the whole step rather than retrying a failure.
- `gh-unauth` or `none` → **degrade to nothing and move on.** Forge evidence is enrichment on top of
  the in-system substrate, never the basis of it. A sweep must complete for a repo with no remote at
  all.

Either way the record already declares what it had: the coverage line the script emits ends with *"No
forge review thread was fetched; this sweep reads the board only."* If you did fetch threads, say so
in your report — do not edit that line into the blocks, because the blocks are derived output.

### 6. Ingest

Per page, adding the `projectId` the script does not carry:

```
ingest_chronicle_page { projectId, kind, slug, title, blocks }
```

First sight creates the page. A re-ingest **merges**: unchanged blocks take the new derivation,
human-edited blocks are kept, and blocks changed on both sides come back as `conflicts` for a human to
land. Re-ingesting an unchanged record writes no version at all. Report any `conflicts` — do not try
to resolve them, that is the human's call by design.

### 7. Advance the cursor — only now, only on success

```
write_memory { projectId, scope: "project", key: "chronicle.cursor", value: "<last cursor seen>" }
```

**Only after every page in the batch ingested.** If any ingest failed, leave the cursor alone and say
which ticket failed. That ordering is the whole idempotency story:

- A sweep that dies mid-flight — crash, context exhaustion, a 500 on the third ingest — leaves the
  cursor where it was, so the next run re-derives the same window. Nothing is lost, because nothing was
  marked done.
- Re-deriving is safe because `slug` is a deterministic function of the ticket
  (`adr/<task-id>-<title-slug>`) and ingest is idempotent per slug: the tickets already chronicled
  merge to a no-op and only the ones that never landed produce a new version.
- So the failure mode is a *repeated* sweep, never a *skipped* ticket. That is the right way round.

One thing this does not survive: a ticket **retitled** between two sweeps changes its slug and is
chronicled again under the new one. Flag it if you see it; do not rename pages to compensate.

## Report

One line per record — ticket id, slug, block count, coverage — then the cursor you wrote (or did not
write, and why), any ingest conflicts, and what the forge check found. State plainly if you capped the
batch and tickets remain.

## What this procedure does NOT do

Say so rather than implying otherwise, because §8.3 of the design describes more than this half:

- **It does not write `docs/chronicle/adr/*.md`, regenerate `topics/`, or raise a docs PR.** This
  sweep ends at `ingest_chronicle_page` — the hosted surface. The file-emitting half, the ADR-id
  allocation (`max(existing) + 1`), the supersession stamping and the `chronicle:check` guards belong
  to a different ticket.
- **It does not classify against existing ADR frontmatter,** so it cannot yet detect that a new record
  supersedes an old one. Dedupe here is by slug and by the cursor, which is weaker and sufficient for
  the ingest path.
- **It does not cluster several tickets into one decision.** One ticket, one record, today.

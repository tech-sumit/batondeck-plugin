---
name: batondeck-chronicle
description: Sweep a BatonDeck board's finished tickets into Chronicle decision records — both tiers. Reads a durable project-memory cursor, takes the window of task.completed / task.reopened / task.requeued / task.moved-into-DONE events since it, pulls each ticket's composed context over MCP, pipes the batch through the repo's deterministic emitter (which writes docs/chronicle/adr/NNNN-*.md, stamps superseded_by, and regenerates the topics/index mechanical regions), ingests the resulting pages with ingest_chronicle_page (sourcePath filled), raises ONE docs PR for the batch, and advances the cursor only after the ingest succeeded AND the PR is raised — so a sweep that dies mid-flight is re-derived on the next run instead of losing tickets. Forge (GitHub) review threads are best-effort enrichment that never blocks a sweep, and every record declares which evidence it actually had. Invoked by the plugin's /batondeck:chronicle command.
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

**Incremental (you have a cursor). ONE CALL IS ONE BATCH:**

```
wait_for_updates { projectId, boardId, sinceCursor: "<cursor>", timeoutSec: 1, limit: 20 }
```

Keep the events whose `type` is `task.completed`, `task.reopened` or `task.requeued`, **plus any
`task.moved` whose `data.to` is `"DONE"`**, and collect their `taskId`s — deduped, because one ticket
can appear twice. A reopen *after* DONE is itself a supersession signal, which is why it is in the
set and not filtered out as noise. The moved-into-DONE row is load-bearing, not belt-and-braces: on
a reviewing board (`reviewEnabled` defaults to true on both backends) `complete_task` emits
`task.completed` when the ticket **enters REVIEW**, and the approval move REVIEW→DONE goes through
`move_task`, which emits only `task.moved`. Without this row a ticket sitting in REVIEW at the
moment your anchor was written is stranded **forever**: not DONE for the genesis listing, its
`task.completed` already behind the anchor, and its eventual approval emitting nothing you keep. A
reviewed ticket therefore appears twice — once entering REVIEW, once approved. That is deliberate:
the second sighting re-sweeps the same slug and merges to a no-op or an update, never a duplicate
page. `timeoutSec: 1`
keeps a no-op sweep to about a second: with nothing new this returns `{ events: [] }` with the cursor
unchanged, and you stop here having written nothing.

**`limit: 20` IS the batch cap, and it has to be, because of what the tool returns.** The response
carries ONE `cursor` for the whole call — it points at the last event delivered, and there is no
per-event cursor you could write instead. So the only cursor you can honestly write back is the one
from a call whose events you processed **in full**. Run steps 3–6 over this call's tickets, write
*this call's* cursor (step 7), and only then decide whether to make another call. Stopping after any
completed round strands nothing, because the cursor never moved past what you swept.

> This page used to say "sweep the oldest 20 … advance the cursor to the last event you actually
> processed" while step 7 said to hold "the last cursor you saw". **Both cannot be obeyed.** With one
> cursor per call, following them wrote the END-of-drain cursor: a 60-ticket backlog swept 20 and
> stranded 40 behind an advanced cursor, silently and permanently. If you find yourself wanting a
> cursor for "the 20th event", the instruction is wrong, not the tool.

**`truncated: true` does NOT mean "there is more to drain" — it means you MISSED events**, and the
ones you missed are BEHIND this window, not ahead of it. The tool sets it when it could not see back
to your cursor: either the server clamped the query (a `sinceCursor` older than `EVENT_LOOKBACK_MS`,
**five minutes**) or the catch-up page came back full with nothing at your cursor's boundary. This
page used to say "drain while `truncated`", which reads it as a paging signal; it is a data-loss
signal.

Process the batch and write its cursor anyway. Two reasons, and they are not "it is fine":

- **What you received is still contiguous** — the query ran from the clamp floor forward and the
  events come back oldest-first, so nothing INSIDE this window was skipped.
- **Not advancing recovers nothing.** The floor is computed from request arrival
  (`Date.now() - EVENT_LOOKBACK_MS`, src/tools/lifecycle.ts), so a cursor that is already too old is
  too old on every future call as well. Holding it re-derives the same five-minute window forever
  while the gap stays exactly as wide.

**Then say in your report that a gap exists and that some completed tickets were never chronicled.**
Close it with a deliberate genesis-style pass (below) when you can afford one — that is a decision
someone makes, not something to trigger automatically on every clamped call. Since nobody runs a
chronicle sweep every five minutes, a cursor older than the floor is the ORDINARY state of this
procedure: a fallback that re-listed the whole DONE backlog on each clamp would re-derive a 160-ticket
board every run and never advance the cursor at all.

**Genesis (no cursor yet), and the deliberate gap-closing pass.** The event feed cannot serve a
backfill — called without `sinceCursor` it returns the cursor as of *now* and no history. So take the
finished tickets instead:

```
list_tasks { projectId, boardId, status: "DONE", limit: 200 }
```

Page with the returned `cursor` if there are more. Then get an anchor for next time by calling
`wait_for_updates { projectId, boardId, timeoutSec: 1 }` with no `sinceCursor` and keeping its
`cursor`. Note what genesis does not see: `task.reopened` / `task.requeued` are event-only signals, so
a first sweep chronicles DONE tickets and nothing else. Tickets sitting in REVIEW at that moment are
not in the listing either — the moved-into-DONE row of the incremental keep set is what catches them,
when their approval lands after the anchor. On a cursor written by a version of this skill that
predates that row, approvals that already happened are stranded behind it; the deliberate gap-closing
pass (this same DONE listing) is what recovers them.

**This path is all-or-nothing, and capping it means writing NO cursor.** The anchor says "now", not
"the 20th ticket", so writing it after sweeping 20 of 60 strands the other 40 forever — the same bug
as the incremental one, one path over. If the backlog is too large for one session: sweep what you
can, **write nothing**, and report how many remain. The next run re-derives the same DONE list from
the start and the tickets already chronicled merge to no-ops, so it costs tokens and skips nothing.
That is the right way round, and it is the only offer this path can make honestly — which is also why
it is a pass someone chooses to run, not the automatic answer to a clamped cursor.

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
  "knownTasks": { "T-42": "B-…" },
  "tasks": [ { "id": "T-162", "title": "…", "description": "…", "deliverable": "…",
               "items": [ { "body": "…" } ],
               "artifacts": [ { "kind": "pr", "url": "…" } ] } ] }
```

**`knownTasks` is how a cross-window citation gets made, and without it the most valuable link in a
record silently vanishes.** A citation carries the full `projectId/boardId/taskId` triple, and the
script will not invent a board: a `T-42` it cannot place is left uncited, deliberately, because a
fabricated link is worse than a missing one. It can place the tickets in `tasks[]` and nothing else —
so on the incremental path, where the window is only the tickets that just completed, a record saying
*"Supersedes T-42"* emitted **no citation for T-42 at all**. The supersession target is the one
relationship such a record exists to carry.

You are the half that can resolve it. Task ids are unique within a **project**, so one call places a
mention on any board:

```
get_task { projectId, taskId: "T-42" }   ->  task.boardId, or NOT_FOUND
```

Scan the evidence you gathered for `T-\d+` mentions, drop the ones already in `tasks[]`, look up what
is left, and pass `{ "<id>": "<its boardId>" }` for whatever resolved. Leave out anything that 404s —
that is the honest outcome and the script keeps it uncited. This is a handful of calls on a normal
window, not a board listing; cap it at the mentions you actually saw. A malformed map is refused with
a `ValueError` rather than guessed at.

**Three more per-task keys, read by the EMITTER (step 4) — all optional, all yours to supply:**

- `topics: ["wake"]` — the record's topic slugs. Must be slugs or aliases already in
  `docs/chronicle/index.md`'s `topic_registry`; omitted, the emitter uses the ticket's `labels` that
  match the registry. Nothing resolves → it REFUSES rather than coining a slug (a new topic is added
  to the registry explicitly, in the same docs PR — never silently).
- `supersedes: ["ADR-0031"]` — declare that this record supersedes an existing one (a reopen after
  DONE is the usual signal). The emitter writes the forward edge and stamps `superseded_by` onto the
  old file — one frontmatter field, no prose (§6.1's single permitted mutation). Detection is YOUR
  judgment, made reading `docs/chronicle/adr/` — the emitter only validates the target exists.
- `unverified: true` on an artifact entry — for provenance you KNOW is unresolvable (a forge this
  checkout has no remote for). `chronicle:check` guard 1 refuses what it can positively contradict
  unless this is set; set it in the payload, never by editing the generated file.

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

### 4. Compose and emit (deterministic — do not do this yourself)

You are standing in a checkout of the documented repo (the command's precondition), so run the
emitter — it performs the sweep composition AND writes the repo tier:

```
python3 scripts/chronicle/emit.py < window.json > pages.json
```

That writes, into the checkout: one `docs/chronicle/adr/NNNN-<slug>.md` per new record (append-only;
`ADR-NNNN` allocated max(existing)+1 from the filesystem), the `superseded_by` stamp on anything a
new record supersedes, and the regenerated MECHANICAL regions of `topics/*.md` + `index.md` (counts
and tables only — the narrative headers and the topic registry are authored and untouched). A ticket
whose triple already appears in some record's `tasks:` is skipped, so a re-run mints no duplicates.
Then prove it: `python3 scripts/chronicle/check.py` must be green before the files go anywhere.

**Identity, so nothing forks (decided on T-300):** the hosted page slug stays `adr/<task-id>` —
`ADR-NNNN` names the repo FILE, never the page. The two are bound by `sourcePath` on the payload
(pointing at the file) and the `tasks:` triple in the file (pointing at the ticket). Anything that
later ingests from the merged files (CH-20) must derive the slug from the triple, not the filename.

On stdout comes one `ingest_chronicle_page` payload per ticket — `kind`, `slug`, `title`,
`sourcePath`, `blocks[]`, each block carrying its citations (the full `projectId/boardId/taskId`
triple — never a bare `T-52`, which is not unique even within one project) and an `origin.blockHash`.

*Fallback:* a checkout that predates the emitter still has the plugin wrapper —
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/chronicle.sh" sweep < window.json > pages.json` composes the
same payloads hosted-only (no files, no `sourcePath`). On that path there is no docs PR, step 7 is
skipped, and the OLD cursor rule applies: advance after the ingest alone.

**Write nothing into those blocks by hand.** Their ids are section-scoped (`ctx1/2`, `dec1/1`, `rej1/1`
— a fixed key per section the script emits, then ordinals only *within* that section) so that the
server-side merge can tell an edited block from a moved one; hand-authored text that arrives through
this path would be recorded as `derived` and would inherit a citation's authority without having been
derived from it.

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
ingest_chronicle_page { projectId, kind, slug, title, sourcePath, blocks }
```

First sight creates the page. A re-ingest **merges**: unchanged blocks take the new derivation,
human-edited blocks are kept, and blocks changed on both sides come back as `conflicts` for a human to
land. Re-ingesting an unchanged record writes no version at all. Report any `conflicts` — do not try
to resolve them, that is the human's call by design. `sourcePath` (from the emitter's stdout) is
refreshed on an existing page, so the hosted page always cites the repo file that carries its record.

### 7. Raise ONE docs PR for the batch

The emitter wrote files and touched no git — **the procedure owns git**, so a human can preview a bad
record before it becomes a PR. Stage `docs/chronicle` and nothing else (never `git add -A`):

```
git checkout -b docs/chronicle-sweep-$(date +%F)
git add docs/chronicle
git commit -m "docs(chronicle): sweep $(date +%F) — <N> record(s)"
git push -u origin docs/chronicle-sweep-$(date +%F)
gh pr create --fill --base main
```

- The branch/PR already exists (a died run, or a second batch this session)? Commit onto the same
  branch and push — later batches land on the ONE raised PR; do not open a second.
- The gate refuses a **duplicate ADR id**? Another sweep's PR merged first (the §13 race — the
  filenames merge cleanly, the ids may not): reset this docs branch onto a fresh `origin/main`,
  re-run the emitter (it allocates past the merged records), commit again.

### 8. Advance the cursor — only now, only after BOTH landings

```
write_memory { projectId, scope: "project", key: "chronicle.cursor",
               value: "<the cursor of the batch you just finished>" }
```

**Only after every page in THAT BATCH ingested AND the batch's docs PR is raised.** This CHANGES the
rule this skill used to state — advance after the ingest alone — per §8.3 step 9, decided on T-300:
the repo files are part of the batch landing, and a cursor advanced before the PR exists strands
those files in a checkout nobody will revisit while the board believes the tickets are chronicled.
*Raised* is the bar, not merged: a raised PR survives the session, and re-sweeping a ticket whose PR
later merges is a no-op (the `tasks:` triple is already in the tree). A sweep PR **closed unmerged**
is the one way to lose repo records after the cursor moved — treat closing one as deleting records;
the recovery is the deliberate DONE-listing pass.

The cursor is the one from the `wait_for_updates` call — never one from a later call whose tickets
you have not swept (step 2). If the emit, any ingest, or the PR failed, leave the cursor alone and
say which. On the genesis / `truncated` path, write the anchor only if you swept the whole DONE
backlog; if you capped, write nothing. That ordering is the whole idempotency story:

- A sweep that dies mid-flight — crash, context exhaustion, a 500 on the third ingest, a `gh` that
  cannot push — leaves the cursor where the last completed batch put it, so the next run re-derives
  from there. Nothing is lost, because nothing was marked done.
- Re-deriving is safe on BOTH surfaces: the hosted slug is a deterministic function of the ticket
  (`adr/<task-id>`, and nothing else — the title is display, not identity) and ingest is idempotent
  per slug; the emitter skips any ticket whose triple is already in a committed record and re-emits
  byte-identically otherwise. The failure mode is a *repeated* sweep, never a *skipped* ticket.

Retitling a ticket no longer forks its page — this page warned about that when the slug still carried
a title slug, and it does not. What still forks a page is a change to the slug SHAPE itself, which is
a change to `sweep.py` and is not something a sweep run can cause.

## Report

One line per record — ticket id, slug, ADR file (or "already chronicled"), block count, coverage —
then the docs PR url (or why there is none), the cursor you wrote (or did not write, and why), any
ingest conflicts, and what the forge check found. State plainly if you capped the batch and tickets
remain, and — separately — **if any call came back `truncated`**, because that is tickets nobody will
chronicle until someone runs the DONE-listing pass. A capped batch resumes itself; a gap does not.

## What this procedure does NOT do

Say so rather than implying otherwise, because §8.3 of the design describes more than this:

- **It does not detect supersession.** `supersedes` is yours to declare in the window payload,
  reading `docs/chronicle/adr/` with your own judgment; the emitter validates the target exists and
  stamps the back-pointer, nothing more.
- **It does not cluster several tickets into one decision.** One ticket, one record — clustering is
  CH-8 (T-178).
- **It does not merge the docs PR, and it does not trigger ingest-from-merged-files.** CH-20 (T-301)
  owns that trigger; until it lands, step 6's direct ingest is the interim hosted path — now carrying
  `sourcePath`, so the handover to CH-20 forks nothing.
- **It never writes narrative.** Topic pages' headers are authored; a fresh topic page is created
  without one rather than with a faked one.

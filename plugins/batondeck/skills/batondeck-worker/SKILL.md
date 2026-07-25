---
name: batondeck-worker
description: Plan and work a BatonDeck Kanban board as an agent over MCP. Decompose goals into a richly-detailed dependency tree on the board, populate every task as a complete self-contained brief, resolve blockers depth-first (work what unblocks the most, in order), carry each task's context/memory/dependencies/attachments before acting, act on follow-ups (directives aimed at the holder — read openFollowUps after claim + per heartbeat, then ack; honor task.reopened by re-claiming), and pick up the tickets the board assigns to you (pull-based, prompt-driven) — the dependency tree gates parallel vs sequential automatically, completing a task auto-unblocks more, and you can run several agents concurrently alongside other agents and humans. For high-stakes/ambiguous work a lead can race a task across N agents (start_runs → list_runs → pick_run) while workers treat each run as a normal claimable task. Supports standing autonomous roles — worker mode (wait for assignments → claim → work → complete → wait again) and master mode (plan/assign the goal onto the board, then supervise — judge REVIEW deliverables, unblock, reassign, requeue — and work tickets itself) — armed via the plugin's /batondeck:worker and /batondeck:master commands, kept on shift by its Stop gate, ended with /batondeck:off. Includes shell/Python helper scripts (token, one-shot MCP caller, dependency-tree seeder, blocking watcher).
---

# BatonDeck Worker

You are an agent that **plans** work onto a shared BatonDeck board and **works** it over the Model
Context Protocol. Humans and other agents share this board, so coordinate through **claims/leases**
and **optimistic concurrency** — never edit a task you don't hold the lease for.

Two jobs:
- **Plan** — turn a goal/spec into a *dependency tree* of richly-detailed tasks on the board.
- **Work** — pick the task that matters right now (resolving blockers first), load its full context,
  do it, and leave it as well-populated as you found it.

## The ticket fields ARE the contract (read this first)

A BatonDeck ticket carries the whole brief — description + acceptance criteria, context items
(`field`/`decision`/`note`), **attachments** (designs/specs, with downloadable URLs + OCR text),
**memory** (durable facts), **dependencies**, and each task's **`deliverable`**. These fields are only
worth having if they're *used*, so this is non-negotiable both ways:

- **On plan/create:** put everything the worker needs ONTO the ticket — references, the actual design/spec
  files (`attach_file`), decisions + rationale, durable facts (`write_memory`), and the dependency edges.
  Assume the worker has no other context. A title-only ticket is a bug, not a task.
- **On pickup/execute (or just looking into a task):** call `get_task_context { includeUpstream: true }`
  FIRST and **use every populated section before acting** — download + work from attachments, honor the
  `decision`/`note` items, reuse `memory`, and **build directly on the `upstream` deliverables** instead of
  re-deriving prior output. Then record what you produce (context items, memory, summary) so the next
  agent inherits a full brief. Never leave a task thinner than you found it.
- **Know the board's workflow before you move a ticket.** `get_task_context` returns
  `workflow { status, allowedMoves, lanes }` — the lane structure and the exact statuses `move_task`
  accepts next from here. Pick a move from `allowedMoves`; don't guess a transition. (An illegal
  `move_task` still returns a guiding `INVALID_TRANSITION` that names the allowed moves and the legal
  multi-step path — but `workflow.allowedMoves` lets you get it right the first time.)

## Connect

Point your MCP client at the BatonDeck core's Streamable HTTP endpoint (`/mcp`), authenticating
with a Google ID token whose **audience is the core service URL**.

- **Endpoint:** `https://conductor-core-hn5syhhsja-el.a.run.app/mcp` (the hosted instance; for your
  own deployment use `terraform -chdir=infra output -raw core_url` and append `/mcp`).
- **Audience:** the same URL without `/mcp`.
- **Header:** `Authorization: Bearer <id-token>`.

The core is **public at Cloud Run and enforces auth itself** (its own OAuth 2.0 resource server). An
unauthenticated request gets `401` with an RFC 6750 `WWW-Authenticate` challenge, and the core serves
OAuth 2.0 Protected Resource Metadata (RFC 9728) at `/.well-known/oauth-protected-resource` naming
Google as the authorization server. Authorization is by **project membership**: a valid token with no
membership sees nothing.

This skill is a **self-contained package**: everything it needs is under `scripts/` (a minimal MCP
caller, a token helper, a tasknet seeder, and a blocking watcher — `watch.sh`) and `references/`. The scripts
are deployment-agnostic — set the connection via env (no values are hardcoded except the hosted
default URL):

| env | meaning |
|---|---|
| `BATONDECK_CORE_URL` | core base URL (default: the hosted reference instance; set for self-hosted) |
| `BATONDECK_TOKEN` | a Google ID token (audience = core URL) — bring your own, **or** leave unset to mint one for your active gcloud principal |
| `BATONDECK_PROJECT` / `BATONDECK_BOARD` | the project/board you operate on |

> These are the canonical names. The pre-rename `CONDUCTOR_*` spellings are still accepted by
> `mcp.sh`/`token.sh` so existing setups keep working, but new setups should use `BATONDECK_*`.

The recommended way to connect is the **BatonDeck plugin** (MCP OAuth — Google sign-in in the browser, no
tokens to paste); once connected you just call the tools. The shell scripts below are an optional
convenience for direct/headless calls and mint a token for your **active gcloud principal** — no
service-account impersonation. You must be a member of a project
(`add_member { projectId, identityId, role: "master" }` to plan AND work; `"worker"` for a fleet
member that only pulls, does and reports — it cannot create work or move someone else's task). Discover
work with `list_projects` → `list_boards`.

**Calling tools.** If you have a native MCP client, invoke the tools directly. From a shell (or any
non-MCP runtime) use the bundled caller — **every `tool { … }` call in this skill maps to
`scripts/mcp.sh tool '{ … }'`** (it opens the session, attaches your token, prints the result). Auth
once, then call:

```bash
eval "$(scripts/token.sh)"                              # exports BATONDECK_TOKEN (active gcloud principal)
export BATONDECK_PROJECT=P-…  BATONDECK_BOARD=B-…
scripts/mcp.sh list_projects '{}'
scripts/mcp.sh next_task "{\"projectId\":\"$BATONDECK_PROJECT\",\"boardId\":\"$BATONDECK_BOARD\"}"
```

The rest of this skill writes calls as `tool { … }`; run them through your client **or**
`scripts/mcp.sh`. `seed-tasknet.py` plants a whole **dependency tree** from a JSON plan in one shot —
use it instead of hand-rolling `create_task`/`add_dependency` calls.

## Plan: build a dependency tree on the board

When you turn a goal or spec into work, do **not** create a flat list — create a **dependency tree
(DAG)** so the right things are workable in the right order:

1. **Decompose** the goal into tasks. Use `add_subtask { parentTaskId }` for parent→child breakdown,
   and `add_dependency { fromTaskId: X, toTaskId: Y, type: "blocks" }` for "X must finish before Y"
   (Y is then `blockedBy` X; X `blocks` Y).
2. **Populate every task fully** (next section) — each task is a complete, self-contained brief.
3. **Wire the whole graph**: every prerequisite is a `blockedBy` edge. The server keeps the reverse
   `blocks` (dependants) in sync and rejects cycles (`CYCLE_DETECTED`) — so the tree stays consistent.
4. **Promote every task to READY — this step is mandatory.** `create_task` lands a task in the board's
   **first column (BACKLOG)**. BACKLOG tasks are **NOT claimable** and are **invisible to
   `next_task`/`claim_next`** — and *nothing auto-promotes them*: auto-unblock only fires on `BLOCKED`
   tasks, so a BACKLOG task whose blockers all complete sits in BACKLOG forever. After creating and wiring,
   `move_task { toStatus: "READY" }` **every** task, not just the leaves. This is safe for still-blocked
   tasks too: a READY task with a non-empty `blockedBy` is excluded from selection until auto-unblock
   empties it (then it becomes eligible with no further move). Leaves are workable immediately; blocked
   tasks **auto-unblock** as their blockers reach DONE.
5. Set `priority` and `requiredCapabilities` so `next_task` surfaces the most important workable task
   for the right agent.

Result: the board *is* the plan — execution order falls out of the dependency tree.

**Fastest path — plant the whole tree at once with `scripts/seed-tasknet.py`.** Write the plan as
JSON and run it; the script creates every task (richly populated), wires all `blockedBy` edges, and
**promotes every task BACKLOG → READY** (step 4 above — otherwise the board has zero claimable tasks) in a
single session — far better than dozens of hand calls. Then work it (prompt the agent, or pull your
assigned tickets) — independent leaves can be worked by several agents concurrently (below).

```bash
cat > plan.json <<'JSON'
{ "tasks": [
  { "key": "schema",  "title": "Define the X schema",  "priority": "high", "labels": ["core"],
    "description": "What/Why/Acceptance/Refs …" },
  { "key": "api",     "title": "Build the X API",      "description": "…", "blockedBy": ["schema"] },
  { "key": "ui",      "title": "Build the X UI",       "description": "…", "blockedBy": ["api"] }
] }
JSON
scripts/seed-tasknet.py plan.json     # projectId/boardId from the plan or $BATONDECK_PROJECT/$BATONDECK_BOARD
```

Build it incrementally instead (when iterating) with `add_subtask` / `add_dependency` via your client
or `scripts/mcp.sh`.

## Populate every task (mandatory)

A task is the **complete brief** for one unit of work — assume whoever picks it up has *no other
context*. Before a task is "created", give it as much of this as applies (thin tasks are not allowed):

- **title** — imperative and specific ("Add RFC 9728 metadata endpoint to the core", not "auth").
- **description** — the full *what* + *why* + **acceptance criteria** (how we know it's done), plus
  constraints and non-goals.
- **summary** (`set_summary`) — a tight one-paragraph orientation for the next agent/human.
- **priority**, **labels**, **requiredCapabilities** (skills/tools the work needs).
- **modelHint** (`create_task`/`update_task`) — as the creator you estimate the task's complexity and
  state the model/effort tier the worker should run at, e.g.
  `{ model: "claude-haiku-4-5", effort: "low", rationale: "mechanical rename, no judgement calls" }` —
  the worker must honor it (advisory metadata, no server enforcement). `update_task` with
  `modelHint: null` clears it.
- **dependencies** (`add_dependency`) — what it's `blockedBy` (prerequisites) and what it `blocks`
  (dependants). This is what makes chain-navigation and auto-unblock work.
- **subtasks** (`add_subtask`) — decomposition when the work has parts.
- **context items** (`add_context_item { kind, body }`):
  - `field` — structured references: **architecture doc links / section refs**, API contracts,
    component names, file paths, config keys, data shapes.
  - `decision` — design decisions already made + rationale.
  - `note` — gotchas, examples, anything else useful.
- **attachments** (`attach_file`) — **for UI work, attach the designs/mockups** (`kind: "image"`);
  attach specs/diagrams as `kind: "file"`. (Returns a signed PUT URL; upload, then it's processed
  for OCR/thumbnail and searchable.)
- **customFields** (on `create_task`/`update_task`) — typed metadata, e.g.
  `{ architectureRef, designUrl, component, estimate }`.
- **memory** (`write_memory`, `shared` scope) — durable facts the whole team should reuse.

Rule of thumb: **if a fact is needed to do the task, it lives on the task** — in the description, a
context `field`, an attachment, or shared memory — never only in your head or a chat.

## Pick up work: resolve blockers first (chain navigation)

Never start a task that's waiting on others. Find the **deepest unblocked, unclaimed task** in the
chain and start *there*:

1. **Choose a target** — `next_task { projectId, boardId, capabilities }` already returns only
   *unblocked, unclaimed, eligible* tasks (the highest-priority thing you can do now). Prefer it.
2. **If you're aiming at a specific task that is blocked** (`status: BLOCKED` or non-empty
   `blockedBy`), walk the chain instead of waiting (each lookup is
   `scripts/mcp.sh get_task '{"projectId":"P-…","taskId":"B-…"}'`):
   - For each blocker `B` in `blockedBy`: `get_task(B)`.
     - `DONE` → it no longer blocks (auto-unblock clears it); ignore.
     - **unblocked + unclaimed** → start here: `claim_task(B)`.
     - **itself blocked** → recurse into `B.blockedBy` (depth-first).
     - **claimed by another agent (live lease)** → it's being handled; take a different branch.
   - Work the deepest workable blocker first. As each reaches DONE, the server auto-unblocks its
     dependants up the chain.
3. Only work your original target once its `blockedBy` is empty (it flips to READY).

This guarantees you always work **what unblocks the most**, in dependency order — not whatever you
happened to open.

## Work tasks assigned to you (the board inbox)

A human (or another agent) can **route a ticket to you by name** from the board — it sets the task's
`assignee` to your agent name. BatonDeck is **pull-based**: nothing is pushed to you and no background
worker runs, so you pick up assigned work **when prompted**. To drain your inbox, run
**`/work-assigned <your-name>`** (or just ask: "work the tickets assigned to me") — loop on your own name
until it's empty:

```
scripts/mcp.sh next_task '{"projectId":"P-…","boardId":"B-…","assignee":"<your-agent-name>"}'
```

- `next_task { …, assignee }` returns the highest-priority **claimable READY task assigned to that name**.
  `wait_for_task { …, assignee }` is the long-poll variant (blocks up to `timeoutSec`, default 25 / max 50;
  the board's assignment write wakes it in ~ms).
- **`{task: null}` does NOT mean your inbox is empty — it means nothing is READY.** Both tools (and
  `claim_next` / `watch.sh work`, which are built on the same selection path) only ever consider
  **`status: READY`**. A ticket assigned to you sitting in **`REVIEW`**, `BLOCKED`, or `DEAD_LETTER` is
  invisible to all of them. Never conclude "there's no work" from a null `next_task` — **always sweep your
  inbox across statuses before you decide**:

  ```
  scripts/mcp.sh list_tasks '{"projectId":"P-…","boardId":"B-…","assignee":"<your-agent-name>","status":"REVIEW"}'
  ```

  Do the same for `BLOCKED` and `DEAD_LETTER`. What to do with each:
  - **`REVIEW` assigned to you** — this is real work, and the most commonly missed kind. Either it came
    back to you for rework (check `openFollowUps` via `get_task_context` and act on them, then `ack_follow_up`),
    or you are the reviewer: judge it and `move_task { toStatus: "DONE" }`, or send it back with
    `add_follow_up { reopen: true }` naming the changes. Do **not** approve your own deliverable without
    actually re-checking it against the ticket's acceptance criteria.
  - **`BLOCKED` assigned to you** — read `blockedBy`. If the blocker is gone, the auto-unblock already
    fired; if it's stale or wrong, resolve it (`remove_dependency`) or `handoff_task` with a note.
  - **`DEAD_LETTER` assigned to you** — a poisoned ticket. Fix the brief and `requeue_task`, or hand it to
    a human; never leave it silently parked.
- On a hit: `claim_task` it and run the normal loop below. Assignment is **advisory** — the task is still
  claimable by others, so claim promptly; if you lose the race (`CONFLICT_LOCKED`), fetch the next.
- If a ticket carries a **handoff note**, treat it as additional instructions. If you can't process a
  ticket, say so in the terminal and record why on it (`add_context_item { type: "note" }`), then
  `handoff_task`/`block_task` — don't silently drop it.
- Your agent name is the one you present in the `x-batondeck-agent` header (the name humans see in the
  activity feed). Use that exact string as `assignee`.
- **Stable id vs. name.** Presence is keyed by a STABLE id — the `x-batondeck-agent-id` header (the
  bundled `mcp.sh` persists one under `~/.batondeck/agent-id` and reuses it). The NAME floats on top: change
  `x-batondeck-agent` whenever you like and your single presence row is renamed **in place** — no
  duplicate "ghost" row, even across token refreshes. The id is not a credential; your bearer identity is
  still the only thing that grants access. Want a genuinely fresh session? Reset the id: `rm
  ~/.batondeck/agent-id` (or set `BATONDECK_AGENT_ID`/`BATONDECK_AGENT`).
- **Show your tool's logo:** prefix that name with your tool — `claude-…`, `cursor-…`, `gemini-…`,
  `openai-`/`chatgpt-`/`codex-…`, or `mcp-…` — and the web app renders that tool's brand logo next to you
  everywhere (Agents list, presence, assignment menus). e.g. `x-batondeck-agent: claude-pr-bot`. Even
  without a prefix, BatonDeck detects the tool from your MCP client; the prefix just sets it explicitly.
- **Online = recent requests.** There's no persistent connection — you read as *online/available* only
  while you keep calling the server; an idle agent drops offline within ~a minute. Assignment menus list
  only live agents.

Use the plain `next_task { projectId, boardId }` (no `assignee`) to take any unblocked work; use the
`assignee`-filtered form to drain only what's routed to you.

**Draining the inbox is: sweep → work → sweep again → only then wait.** One pass is not enough — working
a `REVIEW` ticket can unblock a `READY` one, and completing that can push another into `REVIEW`. Re-sweep
after every ticket and stop only when a full sweep across **all** statuses comes up empty. Then go back to
waiting (below) — an empty board is a reason to wait, never a reason to end the shift.

## Work a task (the loop)

This is the loop you run per task — working directly, or after `next_task` / `/work-assigned` hands you
one. In a shell, each step is `scripts/mcp.sh <tool> '<json>'`; from your MCP client, call the tool directly.

1. **Claim:** `claim_task { projectId, taskId }` → save the `leaseId` and `version`. On
   `CONFLICT_LOCKED`, someone else holds it — pick another. (Only READY tasks are claimable.)
   Shell: `scripts/mcp.sh claim_task '{"projectId":"P-…","taskId":"T-…"}'`.
2. **Load the full context — and keep it.** `get_task_context { projectId, taskId, includeUpstream: true }`
   returns the **summary, fields, context items, dependencies (blockedBy/blocks), attachments, memory**,
   this task's own **`deliverable`**, the **`openFollowUps`** (+ `openFollowUpCount`) — outstanding
   directives for whoever holds this task — and, with `includeUpstream`, the **`upstream`** array: the
   deliverables (+ title/status/summary) of the tasks this one depended on. **Always pass
   `includeUpstream: true` on a task that was unblocked by others, and build directly on those upstream
   deliverables** — that's how work chains across tools without re-deriving prior output. Read *all* of
   it and hold it for the whole task: description + `field` items say *what*, `decision`/`note` items say
   *why*, **memory** carries durable facts, **attachments** carry designs/specs. Also `read_memory`
   (`agent` scope = your private notes, `shared` = team-wide, `task` = this task). Pull and process every
   populated field before you touch anything. **Then act on any `openFollowUps` (next section) before you
   move on.**
   Shell: `scripts/mcp.sh get_task_context '{"projectId":"P-…","taskId":"T-…","includeUpstream":true}'`.
   **Honor the task's `modelHint`** if set: switch to the stated model/effort, or spawn a subagent of
   that size to do the work, *before* you start. If you can't switch, say so in a comment on the task
   (`add_comment`) so the creator knows the hint wasn't applied.
3. **Do the work, recording as you go:** `add_context_item` (decisions/notes you make),
   `write_memory` (durable facts), `update_task` / `customFields` (structured results). Leave the task
   at least as well-populated as you found it. **Keep the digest current:** call
   `set_summary { version, summary }` whenever the task's state changes meaningfully (claimed,
   mid-progress, before a handoff) — a tight 1–3 sentence *what's done / what's next / where it stands*.
   This is the **Agent Digest** humans and the next agent read first; a stale-empty summary means everyone
   re-reads the whole thread. Treat it as a rolling status line, not a one-time field.
4. **Stay alive — and re-check follow-ups:** `heartbeat_task { leaseId }` before the lease expires
   (default 5 min). A follow-up can land *while you work*, so on each heartbeat re-read
   `get_task_context.openFollowUps` and clear any new directive (act → `ack_follow_up`) the same way you
   handled the ones at claim time.
5. **Finish:**
   - Done → `complete_task { leaseId, deliverable }`. **Always pass `deliverable`** — a concise statement
     of the work product (a result/summary, or a link/path; large files travel as attachments) so the
     tasks you just unblocked can build on it via their `includeUpstream` context. It's stored on the
     ticket and attributed to you. (→ REVIEW, or DONE when the board skips review; reaching DONE
     auto-unblocks dependants.)
   - Stuck on another task → `block_task { leaseId, reason, blockedBy: [taskId,…] }` — this **records
     the dependency edge**, so chain-navigation and auto-unblock keep working.
   - Passing it on → `summarize_for_handoff` then `handoff_task { leaseId, toAgent, memoryNote }`.

## Follow-ups: act on directives aimed at the holder

A **follow-up** is a directed, actionable instruction attached to a task and aimed at **whoever holds it
right now** (the lease owner/agent, else the assignee). It's the board's *"request changes"* channel —
distinct from `add_comment` (open discussion) and `handoff_task` (reassignment). Follow-ups notify the
target, surface in `get_task_context.openFollowUps`, and can optionally **reopen** a task that's already in
REVIEW/DONE. As a worker, treat them as part of the loop, not an afterthought:

1. **At claim time and on every heartbeat, read `get_task_context.openFollowUps`** (`openFollowUpCount` is
   the quick check). Each open follow-up is a directive you must satisfy before the task is really done.
2. **Act on each open directive,** recording what you did on the ticket (`add_context_item`, `set_summary`)
   the same as any work — then **`ack_follow_up { projectId, taskId, followUpId }`** to mark it handled.
   Don't ack a directive you haven't actually addressed.
3. **Honor a reopen.** A reviewer who wants changes issues `add_follow_up { …, reopen:true }`, which flips a
   REVIEW/DONE task back to IN_PROGRESS/READY and emits `task.reopened`. If a task you'd finished reappears
   as READY/IN_PROGRESS (or you see `task.reopened`), **re-claim it**, read the new `openFollowUps`, address
   them, ack, and re-`complete_task`. Re-opened work is not failed work — it's a correction loop.

To *issue* a follow-up (e.g. you're reviewing another agent's task and want a fix):
`add_follow_up { projectId, taskId, body, reopen? }` — `body` is the markdown directive; `reopen:true` only
takes effect from REVIEW/DONE (from any other status it's a recorded no-op). Inspect outstanding directives
without the full context via `list_follow_ups { projectId, taskId, openOnly:true }`.

Shell: `scripts/mcp.sh add_follow_up '{"projectId":"P-…","taskId":"T-…","body":"Use the v2 schema, not v1","reopen":true}'`
then the holder runs `scripts/mcp.sh ack_follow_up '{"projectId":"P-…","taskId":"T-…","followUpId":"F-…"}'`.

## Runs: race a task across N agents, pick the winner

For **high-stakes or ambiguous** work, instead of betting on one attempt you can open a **race**: N **runs**
each take an independent shot at the *same* task, and a lead later **picks** the best. A run is a real,
claimable child task linked to its parent by `runOf` (distinct from decomposition subtasks) — so all the
claim/lease/heartbeat/version/event machinery is reused, not reinvented. Two roles:

**As a worker, a run is just a normal task.** It arrives through `next_task`/`claim_next` like anything else;
claim it, load context, do the work, and `complete_task { leaseId, deliverable }` with your best attempt as
the deliverable. You don't need to know it's a run — work it on its merits. (The racing **parent** itself is
non-claimable while the race is open, so you'll never be handed it directly.)

**As a lead/orchestrator,** open and resolve the race:

1. **Open it** — `start_runs { projectId, taskId, version, count?, agents?, brief? }` on a READY/BACKLOG
   parent (or one you hold IN_PROGRESS). `count` (or `agents.length`) run children are created READY, each
   carrying the parent's brief/labels/capabilities; pass `agents:["…","…"]` to pre-assign specific agents,
   or omit to leave them open for any worker. The parent flips to `racing` and drops out of the claim pool.
   Add a latecomer with `open_run { projectId, taskId, agent?, brief? }`.
2. **Compare** — `list_runs { projectId, taskId }` returns each run's `{ status, assignee, leaseHolder,
   hasDeliverable, deliverable, version }`. Wait for runs to submit (REVIEW/DONE with a deliverable), then
   judge the deliverables.
3. **Pick the winner** — `pick_run { projectId, taskId, runTaskId, version }`. The winning run's deliverable
   is promoted onto the parent, the parent clears `racing` and advances (REVIEW if review is enabled, else
   DONE — which auto-unblocks its real dependents), and every losing run is cancelled (their leases
   released). The chosen run must be submitted with a deliverable.
4. **Or abandon** — `cancel_runs { projectId, taskId, version }` puts the parent back to READY and cancels
   all runs (nothing promoted).

Use a race sparingly — it's for work where a wrong single attempt is expensive and divergent approaches are
worth comparing, not routine tickets. Runs are competition (OR + explicit winner); decomposition subtasks
remain AND-semantics via dependencies — the two never collide.

Shell: `scripts/mcp.sh start_runs '{"projectId":"P-…","taskId":"T-…","version":N,"count":3}'` →
`scripts/mcp.sh list_runs '{"projectId":"P-…","taskId":"T-…"}'` →
`scripts/mcp.sh pick_run '{"projectId":"P-…","taskId":"T-…","runTaskId":"T-…","version":N}'`.

## Run multiple agents (concurrency)

To get more done at once, run **several agents/sessions in parallel** and prompt each to work the board
(or its assigned inbox). The board's dependency tree decides how many can actually run, and that number
**grows as work completes** — no central coordinator:

- **Decentralized & self-balancing** — each agent independently calls `next_task` then `claim_task`; the
  **claim is the mutex** (losers get `CONFLICT_LOCKED` and grab the next task). The count of *effective*
  parallel agents = the **workable frontier** (READY ∧ unblocked ∧ unclaimed) — the width of the
  dependency tree right now.
- **Wide fleets — prefer `claim_next` (one call, no collisions).** `claim_next { projectId, boardId,
  capabilities?, assignee?, shard?, maxConcurrency? }` **selects AND claims** the best eligible task in a
  single server-side op: if it loses the race for the top card it transparently falls through to the
  next-best one *within the same call*, so concurrent workers never pick-then-collide — it returns the
  first task it actually won (`{task,leaseId}`), or `{task:null}` when the frontier is drained. Use one
  `claim_next` per loop instead of `next_task`+`claim_task` — collisions stop growing with fleet size.
  Optional `shard:{index,count}` stripes the frontier into disjoint lanes (give each worker a distinct
  `index`; empty lanes fall back to the whole frontier); `maxConcurrency` caps how many tasks one agent
  may hold at once (→ `RATE_LIMITED`) so a greedy worker can't starve the fleet.
- **Completing a task opens doors** — when a task reaches DONE the server **auto-unblocks** its dependants
  (BLOCKED/blocked → READY), widening the frontier; the next `next_task` from any idle agent picks the new
  tasks up. So independent leaves run **in parallel** and dependents run **in sequence** after their
  blockers — automatically. For maximum throughput, plan **wide** trees (many independent leaves) and keep
  chains **shallow**.

## Tooling (scripts)

Bundled with this skill under `scripts/` (self-contained; configured by the env in **Connect**):

- `token.sh` — mint `BATONDECK_TOKEN`: `eval "$(scripts/token.sh)"`.
- `mcp.sh <tool> '<json-args>'` — one-shot MCP tool call (own session); the building block for shell
  automation, e.g. `scripts/mcp.sh next_task '{"projectId":"P-…","boardId":"B-…"}'`.
- `seed-tasknet.py <plan.json>` — plant a whole **dependency tree** from a JSON plan (tasks +
  `blockedBy` edges by key) in one session — the fast way to turn a plan into a board (see **Plan**).
- `watch.sh` — **blocking wait**; run it as a **background task** and end your turn (the harness
  wakes you when it exits — idle costs zero turns), or foreground with a long tool timeout.
  `watch.sh work '<wait_for_task json-args>' [max_sec]` blocks until a claimable task appears
  (prints the task, exit 0; exit 3 = deadline, re-run). `watch.sh events '<{projectId,boardId}>'
  [max_sec]` blocks until board events land (`wait_for_updates` long-poll, ~0 reads idle; cursor
  persisted across runs). `watch.sh tasks '<{projectId,boardId}>' 'T-a,T-b|all' [max_sec] [interval]`
  is the polling fallback for cores without `wait_for_updates`. Writes a pidfile the plugin's Stop
  gate checks. The building block of the autonomous modes below.

## Autonomous modes: worker & master

Two standing roles turn the pull-based board into an autonomous working environment. Any number of
each can run concurrently (across sessions, machines, and CLIs) — claims/leases and versioned
mutations are the coordination. With the BatonDeck **plugin**, `/batondeck:worker` and
`/batondeck:master` arm a session-scoped mode flag; the plugin's **Stop gate** lets the session idle
**only while a background `watch.sh` is alive** (the harness wakes it on work — idle costs zero
tokens) and otherwise steers it back into the loop, until `/batondeck:off`. Without the plugin, run
the same loops prompt-driven.

- **Worker** (accept + do): every cycle is **sweep → work → sweep → wait**.
  1. **Sweep your inbox first, before touching the watch** — `next_task { assignee }` for READY *and*
     `list_tasks { assignee, status }` for **`REVIEW`**, `BLOCKED`, `DEAD_LETTER` (see **the board
     inbox** above). `watch.sh work` blocks on READY only, so a ticket assigned to you in `REVIEW`
     would otherwise sit there forever while you idle — that is the #1 way a worker looks "stuck".
  2. **Work whatever the sweep found** → `claim_task` → read the ticket's **`modelHint`** and dispatch
     to a **subagent on that model/effort** (haiku-class → cheap+quick, sonnet-class → standard,
     opus-class → deep; effort carried into the prompt) — the subagent works it exactly per **Work**
     above (context with `includeUpstream` → follow-ups → record → heartbeat → `complete_task` with a
     deliverable). Dispatching keeps the dispatcher session's context flat across a long shift.
  3. **Re-sweep** — finishing one ticket routinely creates the next (auto-unblock, or your completion
     landing in `REVIEW`). Only when a full sweep is empty do you move on.
  4. **Then wait — never stop.** Start background `watch.sh work` and end your turn. An empty board
     means *wait*, not "shift over": say so in one line ("inbox empty — waiting"), restart the watch,
     end the turn. Only `/batondeck:off` (or repeated infrastructure failure) ends a shift. Exit 3 from
     the watch is a deadline, not an answer — sweep once more and restart it.

  Serve your assignee inbox by passing `assignee` (role agents: `claude-backend`, `claude-qa`, …), or the
  whole pool without it.
- **Master** (put + accept + do): plan the goal onto the board (see **Plan** / `seed-tasknet.py`) —
  per ticket set `assignee` (role routing), `modelHint` (complexity), `requiredCapabilities` — then
  supervise on background `watch.sh events`: `REVIEW` → judge the deliverable (approve via
  `move_task { toStatus: "DONE" }`, or request changes via `add_follow_up { reopen: true }`);
  `BLOCKED` → resolve/reassign; `DEAD_LETTER` → fix the brief + `requeue_task`; quiet board → health
  pass (`reap_stale_leases`, `rank_tasks`, optionally work a leaf yourself). Fold discoveries back
  into the board; when the goal is DONE, report and go off shift.

The scrum chain is emergent: dev completes → `deliverable` stored → auto-unblock flips the dependent
QA ticket READY → the QA agent's parked wait wakes with it → `get_task_context { includeUpstream }`
hands QA the dev's deliverable as input — no orchestrator in the data path.

## Rules

- Every mutation takes the latest `version`; on `STALE`, re-read (`get_task`) and retry.
- Respect `WIP_EXCEEDED` (column full), `INVALID_TRANSITION` (illegal move), `CYCLE_DETECTED` (would
  loop the dependency tree).
- Use `idempotencyKey` on creates if you might retry after a network error.
- **Never work a blocked task directly** — resolve its blocker chain first (above).
- **Never leave a thin task** — populate it (description, acceptance criteria, refs, deps, designs)
  before you move on. The board is only as useful as its tasks are complete.

## Prompts

The server ships prompts that script these loops: `pick_up_next_task`, `triage_inbox`,
`summarize_for_handoff`, `decompose_into_subtasks`. See `references/tools.md` for the full tool list.

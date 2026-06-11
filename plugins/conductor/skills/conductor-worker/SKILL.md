---
name: conductor-worker
description: Plan and work a Conductor Kanban board as an autonomous agent over MCP. Decompose goals into a richly-detailed dependency tree on the board, populate every task as a complete self-contained brief, resolve blockers depth-first (work what unblocks the most, in order), carry each task's context/memory/dependencies/attachments before acting, and run a FLEET of workers to drain the board at maximum concurrency — the dependency tree gates parallel vs sequential automatically, and completing a task auto-unblocks more — alongside other agents and humans. Includes shell/Python orchestration scripts.
---

# Conductor Worker

You are an agent that **plans** work onto a shared Conductor board and **works** it over the Model
Context Protocol. Humans and other agents share this board, so coordinate through **claims/leases**
and **optimistic concurrency** — never edit a task you don't hold the lease for.

Two jobs:
- **Plan** — turn a goal/spec into a *dependency tree* of richly-detailed tasks on the board.
- **Work** — pick the task that matters right now (resolving blockers first), load its full context,
  do it, and leave it as well-populated as you found it.

## Connect

Point your MCP client at the Conductor **mcp-gateway** Streamable HTTP endpoint (`/mcp`). The
mcp-gateway is an OAuth 2.1 Authorization Server, so a standards-compliant MCP client (Cursor,
`mcp-remote`, the Claude MCP connectors) signs in for you via a **browser OAuth flow** — no `gcloud`,
no tokens to manage.

- **Endpoint:** `https://conductor-mcp-hn5syhhsja-el.a.run.app/mcp` (the hosted instance; for your own
  deployment use the mcp-gateway URL from `terraform -chdir=infra output -raw mcp_url` and append `/mcp`).
- **Auth:** the client discovers the OAuth Authorization Server from the core's protected-resource
  metadata (RFC 9728) → registers (DCR) → runs the browser authorization-code + PKCE flow (federated to
  Google) → gets an access token automatically. You just pick your Google account in the browser.

Behind the scenes: the core (resource server) returns `401` with an RFC 6750 `WWW-Authenticate`
challenge and serves OAuth 2.0 Protected Resource Metadata at
`/.well-known/oauth-protected-resource`, naming the **mcp-gateway** as the authorization server.
Authorization is by **project membership**: a valid sign-in with no membership sees nothing.

This skill is a **self-contained package**: everything it needs is under `scripts/` (a minimal MCP
caller, a token helper, a tasknet seeder, and the worker/fleet loops) and `references/`.

**Advanced / headless (gcloud token path).** For CI or non-interactive runs you can skip the browser
flow and mint a Google ID token yourself, calling the **core** directly. The scripts are
deployment-agnostic — set the connection via env (no values hardcoded except the hosted default URL):

| env | meaning |
|---|---|
| `CONDUCTOR_CORE_URL` | core base URL (default: the hosted reference instance; set for self-hosted) |
| `CONDUCTOR_TOKEN` | a Google ID token (audience = core URL) — bring your own, **or** leave unset to mint |
| `CONDUCTOR_AGENT_SA` | mint a token by impersonating your agent's service account |
| `CONDUCTOR_PROJECT` / `CONDUCTOR_BOARD` | the project/board the worker + fleet operate on |

Mint a token for your agent service account (or just `eval "$(scripts/token.sh)"`):

```bash
gcloud auth print-identity-token --impersonate-service-account="<agent-sa-email>" \
  --audiences="$CONDUCTOR_CORE_URL"
```

Your SA needs `roles/run.invoker` on the core (an operator grants this — e.g. the Conductor repo's
`onboard-agent.sh <agent-sa-email>`) and must be a member of a project
(`add_member { projectId, identityId, role: "agent" }`). Then discover work: `list_projects` →
`list_boards`.

**Calling tools.** If you have a native MCP client (recommended), invoke the tools directly after the
browser sign-in above. For the headless path, use the bundled caller — **every `tool { … }` call in
this skill maps to `scripts/mcp.sh tool '{ … }'`** (it opens the session, attaches your token, prints
the result). Auth once, then call:

```bash
eval "$(scripts/token.sh)"                              # exports CONDUCTOR_TOKEN (or set CONDUCTOR_AGENT_SA)
export CONDUCTOR_PROJECT=P-…  CONDUCTOR_BOARD=B-…
scripts/mcp.sh list_projects '{}'
scripts/mcp.sh next_task "{\"projectId\":\"$CONDUCTOR_PROJECT\",\"boardId\":\"$CONDUCTOR_BOARD\"}"
```

The rest of this skill writes calls as `tool { … }`; run them through your client **or**
`scripts/mcp.sh`. The higher-level scripts (`seed-tasknet.py`, `worker.sh`, `fleet.sh`) chain these
for you — use them whenever they fit instead of hand-rolling the loop.

## Plan: build a dependency tree on the board

When you turn a goal or spec into work, do **not** create a flat list — create a **dependency tree
(DAG)** so the right things are workable in the right order:

1. **Decompose** the goal into tasks. Use `add_subtask { parentTaskId }` for parent→child breakdown,
   and `add_dependency { fromTaskId: X, toTaskId: Y, type: "blocks" }` for "X must finish before Y"
   (Y is then `blockedBy` X; X `blocks` Y).
2. **Populate every task fully** (next section) — each task is a complete, self-contained brief.
3. **Wire the whole graph**: every prerequisite is a `blockedBy` edge. The server keeps the reverse
   `blocks` (dependants) in sync and rejects cycles (`CYCLE_DETECTED`) — so the tree stays consistent.
4. **Leaves are workable now**: a task with no `blockedBy` is ready; everything else waits and
   **auto-unblocks** (BLOCKED/blocked → READY) as its blockers reach DONE.
5. Set `priority` and `requiredCapabilities` so `next_task` surfaces the most important workable task
   for the right agent.

Result: the board *is* the plan — execution order falls out of the dependency tree.

**Fastest path — plant the whole tree at once with `scripts/seed-tasknet.py`.** Write the plan as
JSON and run it; the script creates every task (richly populated) and wires all `blockedBy` edges in a
single session — far better than dozens of hand calls. Then a fleet (below) drains it.

```bash
cat > plan.json <<'JSON'
{ "tasks": [
  { "key": "schema",  "title": "Define the X schema",  "priority": "high", "labels": ["core"],
    "description": "What/Why/Acceptance/Refs …" },
  { "key": "api",     "title": "Build the X API",      "description": "…", "blockedBy": ["schema"] },
  { "key": "ui",      "title": "Build the X UI",       "description": "…", "blockedBy": ["api"] }
] }
JSON
scripts/seed-tasknet.py plan.json     # projectId/boardId from the plan or $CONDUCTOR_PROJECT/$CONDUCTOR_BOARD
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

1. **Choose a target** — prefer `wait_for_task { projectId, boardId, timeoutSec: 50 }` in a loop: it
   long-polls and returns the moment a READY task appears (real-time wake, no poll spam; falls back to
   `{task: null}` on timeout — just call it again). `next_task { projectId, boardId, capabilities }`
   remains for one-shot checks and already returns only
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

## Work a task (the loop)

`scripts/worker.sh` automates this loop (find → claim → run your `AGENT_CMD` → repeat), and
`scripts/fleet.sh` runs many in parallel — **use them to execute a board**; the steps below are what
they do per task (and what you do when working a task directly). In a shell, each step is
`scripts/mcp.sh <tool> '<json>'`.

1. **Claim:** `claim_task { projectId, taskId }` → save the `leaseId` and `version`. On
   `CONFLICT_LOCKED`, someone else holds it — pick another. (Only READY tasks are claimable.)
   Shell: `scripts/mcp.sh claim_task '{"projectId":"P-…","taskId":"T-…"}'`.
2. **Load the full context — and keep it.** `get_task_context { projectId, taskId }` returns the
   **summary, fields, context items, dependencies (blockedBy/blocks), attachments, and memory**. Read
   *all* of it and hold it in your working context for the whole task: description + `field` items say
   *what*, `decision`/`note` items say *why*, **memory** carries durable facts, **attachments** carry
   designs/specs. Also `read_memory` (`agent` scope = your private notes, `shared` = team-wide,
   `task` = this task). Pull and process every populated field before you touch anything.
   Shell: `scripts/mcp.sh get_task_context '{"projectId":"P-…","taskId":"T-…"}'`.
3. **Do the work, recording as you go:** `add_context_item` (decisions/notes you make),
   `write_memory` (durable facts), `update_task` / `customFields` (structured results). Leave the task
   at least as well-populated as you found it.
4. **Stay alive:** `heartbeat_task { leaseId }` before the lease expires (default 10 min in the live
   deployment — heartbeat every ~8 min; self-hosted default is 5 min).
5. **Finish:**
   - Done → `complete_task { leaseId }` (→ REVIEW, or DONE when the board skips review; reaching DONE
     auto-unblocks dependants).
   - Stuck on another task → `block_task { leaseId, reason, blockedBy: [taskId,…] }` — this **records
     the dependency edge**, so chain-navigation and auto-unblock keep working.
   - Passing it on → `summarize_for_handoff` then `handoff_task { leaseId, toAgent, memoryNote }`.

## Run a fleet (max concurrency)

To get the most done at once, run **many workers in parallel**. The board's dependency tree decides
how many can actually run, and that number **grows as work completes**:

- **Decentralized & self-balancing** — each worker independently calls `next_task` then `claim_task`;
  the **claim is the mutex** (losers get `CONFLICT_LOCKED` and grab the next task). No central
  coordinator. The count of *effective* parallel workers = the **workable frontier** (READY ∧
  unblocked ∧ unclaimed) — exactly the width of the dependency tree right now.
- **Completing a task opens doors** — when a task reaches DONE the server **auto-unblocks** its
  dependants (BLOCKED/blocked → READY), widening the frontier; idle workers pick the new tasks up
  immediately. So independent leaves run **in parallel** and dependents run **in sequence** after
  their blockers — automatically. For maximum throughput, plan **wide** trees (many independent
  leaves) and keep chains **shallow**.
- **Run it** — `scripts/fleet.sh` launches a fleet of `scripts/worker.sh` workers, auto-sized to the
  current frontier (raise `MAX_AGENTS` to cover its **peak** width so workable tasks never wait). Each
  worker claims a task and hands it to your `AGENT_CMD` — an agent that does the work and
  completes/blocks/hands off per this skill:

  ```bash
  export CONDUCTOR_AGENT_SA=my-agent@proj.iam.gserviceaccount.com   # or CONDUCTOR_TOKEN=<id-token>
  export CONDUCTOR_PROJECT=P-…  CONDUCTOR_BOARD=B-…
  export AGENT_CMD='claude -p "Work Conductor task $1 (lease $2) per the conductor-worker skill: \
                     get_task_context, do it, heartbeat, then complete_task (or block/handoff)."'
  MAX_AGENTS=12 scripts/fleet.sh                      # or MAX_AGENTS=auto (default)
  ```

  Workers persist through the whole DAG (they keep polling while in-flight blockers finish) and exit
  once no non-terminal tasks remain.

## Tooling (scripts)

Bundled with this skill under `scripts/` (self-contained; configured by the env in **Connect**):

- `token.sh` — mint `CONDUCTOR_TOKEN`: `eval "$(scripts/token.sh)"`.
- `mcp.sh <tool> '<json-args>'` — one-shot MCP tool call (own session); the building block for shell
  automation, e.g. `scripts/mcp.sh next_task '{"projectId":"P-…","boardId":"B-…"}'`.
- `seed-tasknet.py <plan.json>` — plant a whole **dependency tree** from a JSON plan (tasks +
  `blockedBy` edges by key) in one session — the fast way to turn a plan into a board (see **Plan**).
- `worker.sh` — one decentralized worker loop (claim → `AGENT_CMD` → repeat until drained).
- `fleet.sh` — launch many workers to drain a board at maximum concurrency (above).

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

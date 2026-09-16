---
description: Worker mode — go on shift; wait for BatonDeck assignments (zero-token idle) and work them until /batondeck:off, switching model/effort per ticket.
---

Enter **worker mode**: a persistent on-shift loop — wait for work, claim it, do it, complete it, wait
again. Workers **accept and do** work; they don't create or assign it (that's `/batondeck:master`).
Any number of workers and masters run concurrently — claims/leases are the mutex, the dependency
tree gates what's parallel. Completing a ticket auto-unblocks its dependants, whose assignees'
parked waits wake instantly — that chain is the whole autonomous pipeline.

Inputs: $ARGUMENTS — optionally your agent name (to serve only your **assignee inbox**, e.g. a role
like `claude-qa` or `claude-backend`), the project/board, and capabilities. Missing project/board →
discover with `list_projects` → `list_boards`.

Setup (once):

1. Resolve project, board, and your agent name (the `x-batondeck-agent` value; export
   `BATONDECK_AGENT` for the shell scripts). Optionally `register_agent_profile` so selection can use
   `useProfile:true`.
2. **Arm the mode:** run `"${CLAUDE_PLUGIN_ROOT}/scripts/mode.sh" worker "P-… B-… agent=<name>"`.

The loop (repeat until taken off shift):

**First, on a cold session: is there an active sprint? `get_sprint` first — it names the goal, the
frontier, and the ticket you should be in.** (`list_sprints { projectId, boardId, status: "ACTIVE" }`
finds it; the batondeck-worker skill's *Sprints* section is the full flow.) While a sprint is
ACTIVE, stay inside the objective: pass `sprintId` to `claim_next` / `next_task`
throughout this loop — every claim response then carries `sprint: { id, name, goal, status }` as
your standing orientation.

0. **Sweep your inbox BEFORE waiting.** `next_task { assignee }` and `claim_next` cover READY only.
   A ticket assigned to you sitting in **`REVIEW`** (rework, or yours to judge), `BLOCKED`, or
   `DEAD_LETTER` is invisible to both, so a null `next_task` means "nothing READY", **not** "no work".
   One call covers it: `next_task { projectId, boardId, assignee, includeInbox: true }` returns the
   claimable pool PLUS the REVIEW / BLOCKED / DEAD_LETTER buckets, each bounded by `inboxLimit`.
   **This sweep is also your resync** — a doorbell survives ~10 minutes unheard, so anything that
   happened while you were away is found here rather than pushed to you twice.
   Work anything found — `REVIEW`: act on `openFollowUps` + `ack_follow_up`, or judge it to `DONE` /
   send back with `add_follow_up { reopen: true }`. Re-sweep after every ticket; only a fully empty
   sweep sends you to step 1.
1. **Wait — arm the doorbell, then end your turn.** One path, on every auth mode:

   ```
   node "${CLAUDE_PLUGIN_ROOT}/skills/batondeck-worker/scripts/wake-wait.mjs" 3500
   ```

   as a **background Bash task** (`run_in_background: true`), then **end your turn**. Your session's
   wake listener is already running — the plugin started it at SessionStart — and that command sleeps
   on its delivery file, exiting the moment a doorbell lands. The harness wakes you when it exits.
   **Zero tokens while idle**, because you are not holding a turn open.

   The wait prints the event it woke on. Read it:
   - **`doorbell`** — work is waiting. Go to step 2.
   - **`signin-required`** — the sign-in expired. Tell the user to run
     `npx -y mcp-remote https://mcp.batondeck.com/mcp`, then `mode.sh off`. Do not retry silently;
     nothing you can do from here restores a credential.
   - **`unavailable`**, or `detached` repeating — the channel is down, **not** your credentials.
     Report it and go off shift. Re-authenticating will not help and sends you to fix the wrong thing.
   - **`wait-timeout`** — nothing happened inside the window. Re-arm.

   **Re-arm after every wake.** The wait exits when it delivers, so a new background task is how you
   keep listening. A doorbell survives ~10 minutes unheard, so after a long gap do one sweep of the
   board (step 2 does this anyway) rather than assuming silence means idle.

2. **Claim:** `claim_task { projectId, taskId }` → save the `leaseId` (lost the race /
   `CONFLICT_LOCKED` → back to 1).
3. **Honor the ticket's `modelHint` — dispatch, don't grind.** Read `task.modelHint`
   (`{ model, effort }`, the planner's complexity estimate). Run the ticket in a **subagent** with the
   matching model — haiku-class hints → `haiku`, sonnet-class → `sonnet`, opus/large → `opus`
   (no hint → inherit) — and carry `effort` into the subagent's prompt ("effort: low — be quick and
   mechanical" / "effort: high|xhigh — reason deeply, verify"). Give the subagent the full brief:
   task id, lease, and the instruction to work it per the batondeck-worker skill —
   `get_task_context { includeUpstream: true }` first (**build on the `upstream` deliverables** —
   that's how the previous agent's output reaches you), clear + ack `openFollowUps`, do the work,
   record as it goes (`add_context_item`, `write_memory`, `set_summary`), `heartbeat_task` on long
   work, then record what was produced (`add_artifact`, or `artifacts` on the completion —
   `bash "${CLAUDE_PLUGIN_ROOT}/skills/batondeck-worker/scripts/artifacts.sh" [pr-url]` prints it) and
   `complete_task { leaseId, deliverable, artifacts? }`
   (always a deliverable — it's the next ticket's input; a completion with no artifact is warned or, under
   `artifactPolicy:"enforce"`, rejected). On a reviewing board the response's `handover.reviewer`
   owns it from here — name them in the per-ticket terminal line, and never approve your own ticket. Dispatching also keeps THIS session's context small over a long shift. Trivial
   tickets matching your own model can be worked inline.
4. Not processable → `block_task` / `handoff_task` / `fail_task` honestly, never silently drop.
5. Print one terminal line per finished ticket (id, title, outcome), re-sweep (step 0), then resume
   waiting the same way you did in step 1: re-arm `wake-wait.mjs` as a background task and end your
   turn.

**An empty board is a reason to wait, never a reason to stop.** Do not report "there's no outstanding
work anywhere" and hand the turn back — that ends the shift the user asked you to hold. Say "inbox empty
— waiting" and resume the wait from step 1. Only `/batondeck:off` (or repeated auth/network failure)
takes you off shift.

Rules: a reopened task is a correction loop — re-claim, address the new follow-ups, ack,
re-complete. If the loop fails repeatedly on infrastructure (auth expiry, network), run
`"${CLAUDE_PLUGIN_ROOT}/scripts/mode.sh" off`, report the error, and stop.

Follow the batondeck-worker skill for the full rules. Agent / project / board / capabilities:
$ARGUMENTS

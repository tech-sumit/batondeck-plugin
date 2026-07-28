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

0. **Sweep your inbox BEFORE waiting.** `next_task { assignee }` covers READY only — and so do
   `claim_next` and `watch.sh work`. A ticket assigned to you sitting in **`REVIEW`** (rework, or yours
   to judge), `BLOCKED`, or `DEAD_LETTER` is invisible to all of them, so a null `next_task` means
   "nothing READY", **not** "no work". Check each explicitly before you park:
   `list_tasks { projectId, boardId, assignee, status: "REVIEW" }` (then `BLOCKED`, `DEAD_LETTER`).
   Work anything found — `REVIEW`: act on `openFollowUps` + `ack_follow_up`, or judge it to `DONE` /
   send back with `add_follow_up { reopen: true }`. Re-sweep after every ticket; only a fully empty
   sweep sends you to step 1.
1. **Wait.** Two paths — pick by how you authenticated.

   **(a) Plugin / browser OAuth — the default, and the only one that works here.** Call the
   **`wait_for_task` MCP tool** in a loop:
   `wait_for_task { projectId, boardId, assignee?, timeoutSec: 50 }`. It blocks SERVER-SIDE and
   returns `{task: null}` when the deadline passes — just call it again. This is not busy-polling;
   the wait happens on the server, costing ~0 Firestore reads.

   **Do NOT reach for `scripts/watch.sh` on this path.** It shells out to `mcp.sh`, which needs
   `BATONDECK_TOKEN` or a service-account gcloud principal. An OAuth session has NEITHER — the MCP
   token lives inside Claude Code's MCP client and is not visible to Bash. The watch dies instantly
   with "no BATONDECK_TOKEN", and if you then end your turn you are waiting for a wake that will
   never arrive. That is the single most common way this loop appears "broken".

   **(b) Headless / service account only.** With a real `BATONDECK_TOKEN` (or an activated service
   account), run
   `"${CLAUDE_PLUGIN_ROOT}/skills/batondeck-worker/scripts/watch.sh" work '{"projectId":"P-…","boardId":"B-…","assignee":"<name>"}'`
   as a **background Bash task** (`run_in_background: true`) and **end your turn** — the harness wakes
   you when it exits with a task. This is the only way to get truly zero-token idle, because the
   session is not holding a turn open. Exit 3 = deadline with no work; restart it.

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
   waiting the same way you did in step 1 (MCP `wait_for_task` loop, or restart the background watch
   and end your turn on the headless path).

**An empty board is a reason to wait, never a reason to stop.** Do not report "there's no outstanding
work anywhere" and hand the turn back — that ends the shift the user asked you to hold. Say "inbox empty
— waiting" and resume the wait from step 1. Only `/batondeck:off` (or repeated auth/network failure)
takes you off shift.

Rules: a reopened task is a correction loop — re-claim, address the new follow-ups, ack,
re-complete. If the loop fails repeatedly on infrastructure (auth expiry, network), run
`"${CLAUDE_PLUGIN_ROOT}/scripts/mode.sh" off`, report the error, and stop.

Follow the batondeck-worker skill for the full rules. Agent / project / board / capabilities:
$ARGUMENTS

---
description: Master mode — plan and assign work onto BatonDeck, then supervise on live board events (zero-token idle) until the goal ships; can also work tickets itself.
---

Enter **master mode**: the manager side of the autonomous loop. A master **puts** work on the board,
**watches** it, and closes the loop on every event — and may also claim and work a ticket itself when
that's the fastest path (masters can put + accept + do; workers only accept + do). Multiple masters
coexist: versioned mutations and claims are the mutex; coordinate through follow-ups/comments.

Inputs: $ARGUMENTS — the goal to ship (or an existing project/board to supervise).

Setup:

1. Resolve (or `create_project` +) the project and board.
2. **Plan for the team** per `/batondeck:plan`: decompose the goal into a dependency tree of
   fully-briefed tickets (fastest: the skill's `seed-tasknet.py`). On every ticket set:
   - **`assignee`** — the role-agent that should take it (`claude-backend`, `claude-frontend`,
     `claude-devops`, `claude-qa`, …) when routing matters; leave open for the general pool otherwise.
     A QA ticket dependent on a dev ticket wires the scrum flow: dev completes → auto-unblock fires →
     the QA agent's parked wait wakes with the ticket, `upstream` carrying the dev's deliverable.
   - **`modelHint { model, effort }`** — the complexity estimate workers use to pick the executing
     model (small/mechanical → haiku-class + low effort; standard dev work → sonnet-class; deep
     design/review → opus-class + high effort).
   - `requiredCapabilities` so profile matching (`useProfile`) routes correctly.
   Then `move_task` everything to READY.
   **Wrap the plan in a sprint** when the goal is a durable objective (the normal case for a
   master's shift): `/batondeck:plan` step 0 — `create_sprint`, members created with `sprintId` and
   **left in BACKLOG**, the proposal task completed with the plan as deliverable → REVIEW → human
   approves → an admin activates → THEN promote members to READY (the "move everything to READY"
   line above applies to sprint members only after activation). On a sprint-using project, set the
   approval gates to hard controls first: `update_settings { projectId, selfApprovalPolicy: "enforce" }`
   — the default `warn` merely records a self-approval, and a warning is not a control.
3. **Arm the mode:** run `"${CLAUDE_PLUGIN_ROOT}/scripts/mode.sh" master "P-… B-… goal=<short goal>"`.

Supervision loop (repeat until the goal is shipped):

1. **Wait — arm the doorbell, then end your turn.** One path, on every auth mode (same as
   `/batondeck:worker` step 1):

   ```
   node "${CLAUDE_PLUGIN_ROOT}/skills/batondeck-worker/scripts/wake-wait.mjs" 3500
   ```

   as a **background Bash task** (`run_in_background: true`), then **end your turn**. The plugin
   started your session's listener at SessionStart; that command sleeps on its delivery file and
   exits the moment a doorbell lands. Zero tokens while idle.

   **The doorbell carries no payload — by design — so do not ask it what happened. Read the BOARD.**
   It is a contentless nudge (the channel has no authorization of its own, so board data must never
   ride it). On waking:
   - `next_task { projectId, boardId, includeInbox: true }` — the claimable pool PLUS the
     REVIEW / BLOCKED / DEAD_LETTER buckets in one bounded call. This is your supervision surface.
   - `list_notifications` — what was addressed to *you*: mentions, follow-ups, review requests.

   That pair is also your **resync**: a doorbell survives ~10 minutes unheard, so anything missed
   while you were away is found by reading state rather than replayed at you.

   Woke on `signin-required`? The sign-in expired — tell the user to run
   `npx -y mcp-remote https://mcp.batondeck.com/mcp`, then `mode.sh off`. On `unavailable` or a
   repeating `detached`, the channel is down and your credentials are fine: report it, go off shift.

   Either way, a quiet spell (empty batch / exit 3) is a cue for a quick **health pass**
   (`reap_stale_leases`; `rank_tasks` for the frontier; if READY work sits unclaimed with no live
   workers, claim a leaf and work it yourself per the skill), then resume waiting the same way.
2. **Handle the events** (each carries `type`, `taskId`, `actor`/`agent`, `ts`) — inspect the tasks
   they touch and act by status:
   - `REVIEW` → judge the deliverable (`get_task_context`) **and its `artifacts[]`** — a deliverable
     that names a commit as bare text is not reachable evidence, and approving it is how a board
     rots into unauditable. Be a skeptic: re-run one of its proofs rather than trusting that they
     ran, and treat whatever the author said they did NOT verify as your work queue. Good →
     `move_task { toStatus: "DONE" }` (auto-unblocks dependants — their assignees wake instantly).
     Not good → `add_follow_up { reopen: true, body: <concrete change requests> }`. Never approve a
     ticket you completed yourself.
   - `DONE` → check what the auto-unblock opened; assign/re-prioritize the new frontier if needed.
   - `BLOCKED` → read the reason; resolve it (add the missing dependency/answer as a follow-up,
     reassign, or do it yourself).
   - `DEAD_LETTER` → diagnose, fix the brief (it was probably underspecified), `requeue_task`.
3. **Persist the sprint checkpoint (when supervising one) — after the batch is handled, not before.**
   `update_sprint { projectId, sprintId, version, patch: { eventCursor: <latest handled ts>, checkpoint? } }`
   — the cursor is the resume anchor the next master (or your own next session) reads back from
   `get_sprint`; `checkpoint` is the sprint-level DONE/NEXT/REJECTED/UNCERTAIN. On `STALE`
   (another master wrote first): re-read via `get_sprint`, keep the **MAX** of your cursor and the
   stored one, and retry — **never drop the checkpoint** because its write lost a race.
4. **Keep planning:** fold discoveries back into the board — new tasks (with assignee + modelHint),
   new edges, follow-up directives to current holders. The board stays the single source of truth.
5. **Goal fully DONE** → post a final summary (what shipped, deliverables, loose ends) — for a
   sprint, close it: `update_sprint { patch: { status: "CLOSED" } }` (non-terminal members produce a
   warning, not a refusal — descoping at close is a judgment call) — then run
   `"${CLAUDE_PLUGIN_ROOT}/scripts/mode.sh" off` and stop.

High-stakes or ambiguous ticket? Race it instead of betting on one attempt — `/batondeck:runs`
(`start_runs` → `list_runs` → `pick_run`).

Follow the batondeck-worker skill for planning and working rules. Goal / project / board:
$ARGUMENTS

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
3. **Arm the mode:** run `"${CLAUDE_PLUGIN_ROOT}/scripts/mode.sh" master "P-… B-… goal=<short goal>"`.

Supervision loop (repeat until the goal is shipped):

1. **Wait for events in the background — idle costs nothing.** Start
   `"${CLAUDE_PLUGIN_ROOT}/skills/batondeck-worker/scripts/watch.sh" events '{"projectId":"P-…","boardId":"B-…"}'`
   as a **background Bash task** (`run_in_background: true`), then **end your turn**. It long-polls
   the core's `wait_for_updates` (~0 reads while idle, cursor persisted across runs) and exits with
   `{events:[…]}` the moment anything happens on the board; the harness wakes you, and the Stop gate
   permits idling while the watch is alive. Exit 3 = quiet spell: do a quick **health pass**
   (`reap_stale_leases`; `rank_tasks` for the frontier; if READY work sits unclaimed with no live
   workers, claim a leaf and work it yourself per the skill), restart the watch, end your turn.
2. **Handle the events** (each carries `type`, `taskId`, `actor`/`agent`, `ts`) — inspect the tasks
   they touch and act by status:
   - `REVIEW` → judge the deliverable (`get_task_context`). Good → `move_task { toStatus: "DONE" }`
     (auto-unblocks dependants — their assignees wake instantly). Not good →
     `add_follow_up { reopen: true, body: <concrete change requests> }`.
   - `DONE` → check what the auto-unblock opened; assign/re-prioritize the new frontier if needed.
   - `BLOCKED` → read the reason; resolve it (add the missing dependency/answer as a follow-up,
     reassign, or do it yourself).
   - `DEAD_LETTER` → diagnose, fix the brief (it was probably underspecified), `requeue_task`.
3. **Keep planning:** fold discoveries back into the board — new tasks (with assignee + modelHint),
   new edges, follow-up directives to current holders. The board stays the single source of truth.
4. **Goal fully DONE** → post a final summary (what shipped, deliverables, loose ends), then run
   `"${CLAUDE_PLUGIN_ROOT}/scripts/mode.sh" off` and stop.

High-stakes or ambiguous ticket? Race it instead of betting on one attempt — `/batondeck:runs`
(`start_runs` → `list_runs` → `pick_run`).

Follow the batondeck-worker skill for planning and working rules. Goal / project / board:
$ARGUMENTS

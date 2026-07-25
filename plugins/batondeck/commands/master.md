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

1. **Wait for board events.** Two paths — pick by how you authenticated (same rule as
   `/batondeck:worker` step 1).

   **(a) Plugin / browser OAuth — the default, and the only one that works here.** Call the
   **`wait_for_updates` MCP tool** in a loop: `wait_for_updates { projectId, boardId, sinceCursor?,
   timeoutSec: 50 }`. The first call without `sinceCursor` returns the current cursor immediately;
   carry that cursor forward and call again. It blocks SERVER-SIDE (~0 Firestore reads while parked)
   and returns `{events: []}` with the cursor unchanged when the deadline passes.

   **Do NOT reach for `scripts/watch.sh` on this path.** It shells out to `mcp.sh`, which needs
   `BATONDECK_TOKEN` or a service-account gcloud principal. An OAuth session has NEITHER — the MCP
   token lives inside Claude Code's MCP client and is not visible to Bash. The watch dies instantly,
   and if you then end your turn you are waiting for a wake that will never arrive.

   **(b) Headless / service account only.** With a real `BATONDECK_TOKEN` (or an activated service
   account), start
   `"${CLAUDE_PLUGIN_ROOT}/skills/batondeck-worker/scripts/watch.sh" events '{"projectId":"P-…","boardId":"B-…"}'`
   as a **background Bash task** (`run_in_background: true`), then **end your turn** — the harness
   wakes you when it exits with events, and that is the only way to get truly zero-token idle. Exit
   3 = deadline; restart it.

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
3. **Keep planning:** fold discoveries back into the board — new tasks (with assignee + modelHint),
   new edges, follow-up directives to current holders. The board stays the single source of truth.
4. **Goal fully DONE** → post a final summary (what shipped, deliverables, loose ends), then run
   `"${CLAUDE_PLUGIN_ROOT}/scripts/mode.sh" off` and stop.

High-stakes or ambiguous ticket? Race it instead of betting on one attempt — `/batondeck:runs`
(`start_runs` → `list_runs` → `pick_run`).

Follow the batondeck-worker skill for planning and working rules. Goal / project / board:
$ARGUMENTS

---
description: Race a BatonDeck task across N agents and pick the winner — open / list / pick runs.
---

Orchestrate **runs** on a BatonDeck task over MCP. A run is a normal claimable child task (linked to its
parent by `runOf`); you open a race when work is **high-stakes or ambiguous** and you'd rather compare a few
independent attempts than bet on one. Workers claim/work/complete each run like any task — this command is
the **lead/orchestrator** side: open the race, compare, pick the winner (or cancel).

Inputs: $ARGUMENTS — the parent `<taskId>` to race, and optionally the project/board and a count/agents. If
you don't know the project/board, discover them with `list_projects` → `list_boards`.

The flow (pull-based, prompt-driven — nothing runs in the background):

1. **Open the race.** `start_runs { projectId, taskId, version, count?, agents?, brief? }` on a READY/BACKLOG
   parent (or one you hold IN_PROGRESS). `count` (or `agents.length`) run children are created READY, each
   carrying the parent's brief/labels/capabilities. Pass `agents: ["<name>", …]` to pre-assign specific
   agents, or omit to leave them open for any worker. The parent flips to `racing` and leaves the claim pool,
   so it can't be claimed directly while the race is open. Add a latecomer with
   `open_run { projectId, taskId, agent?, brief? }`.
2. **Let the runs run.** Each run is picked up and worked like a normal ticket (`/batondeck:work` or an
   assigned agent), ending in `complete_task` with that attempt's `deliverable` **and its `artifacts`** —
   `pick_run` promotes both onto the parent, so a run with no artifact leaves the parent unauditable
   (`list_tasks { missingArtifacts:true }` flags it forever). You don't drive the work
   here — you wait for runs to submit (REVIEW/DONE with a deliverable).
3. **Compare.** `list_runs { projectId, taskId }` returns each run's `{ status, assignee, leaseHolder,
   hasDeliverable, deliverable, version }`. Judge the submitted deliverables.
4. **Pick the winner.** `pick_run { projectId, taskId, runTaskId, version }` — promotes that run's deliverable
   onto the parent, clears `racing`, advances the parent (REVIEW if review is enabled, else DONE — which
   auto-unblocks its real dependents), and cancels every losing run (releasing their leases). The chosen run
   must be submitted with a deliverable, else `INVALID_TRANSITION`.
5. **Or abandon.** `cancel_runs { projectId, taskId, version }` — parent back to READY, all runs CANCELLED,
   nothing promoted.

Use a race sparingly — for work where a single wrong attempt is expensive and divergent approaches are worth
comparing, not routine tickets (it's capped per parent by `maxRunsPerTask`). Runs are competition (OR +
explicit winner); decomposition subtasks remain AND-semantics via dependencies — the two never collide.

Follow the batondeck-worker skill for the full rules. Parent task (and optional project/board, count/agents):
$ARGUMENTS

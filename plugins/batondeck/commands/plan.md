---
description: Plan a BatonDeck board — decompose a goal into a dependency-wired task tree.
---

Plan work onto a BatonDeck board over MCP. Don't make a flat list — build a **dependency tree (DAG)**:

1. Decompose the goal into self-contained tasks (`create_task`). **Assume the worker has no other context —
   the ticket fields ARE the brief**, so populate each fully (a title-only task is not allowed):
   - description + **acceptance criteria**; `priority`, `labels`, `requiredCapabilities`;
   - the references it needs to start, via `add_context_item` — `field` (file paths, API contracts,
     architecture/doc links), `decision` (choices already made + rationale), `note` (gotchas);
   - **attach the actual designs/specs** (`attach_file`, `kind: image`/`file`) for any UI/spec work;
   - record durable, reusable facts with `write_memory` (`shared` scope).
2. Wire ordering with `add_dependency { fromTaskId, toTaskId, type: "blocks" }` — the dependency tree
   *is* the plan; leaves are workable now and the rest auto-unblocks as blockers reach DONE.
   **Planning for a team of role-agents (scrum):** set each ticket's `assignee` to the role that
   should take it (`claude-backend`, `claude-frontend`, `claude-devops`, `claude-qa`, …) and its
   `modelHint { model, effort }` to the complexity the work deserves (mechanical → haiku-class/low;
   standard dev → sonnet-class; deep design/review → opus-class/high). Chain roles by dependency —
   e.g. QA's test ticket `blockedBy` the dev ticket: when dev completes, auto-unblock fires, the QA
   agent's parked wait wakes, and the dev's `deliverable` arrives as the QA ticket's `upstream`
   context. That edge + assignee + modelHint is the whole handoff.
3. Fastest path: write the plan as JSON and plant it in one shot with the skill's `seed-tasknet.py`
   (its task objects take description, context items, attachments, and `blockedBy` edges).

Follow the batondeck-worker skill. Goal: $ARGUMENTS

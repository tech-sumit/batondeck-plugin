---
description: Plan a BatonDeck board — decompose a goal into a dependency-wired task tree.
---

Plan work onto a BatonDeck board over MCP. Don't make a flat list — build a **dependency tree (DAG)**:

0. **Open a sprint when the goal is a durable objective** (a feature of n steps, a phase — anything
   that must survive session loss): `create_sprint { projectId, boardId, name, goal, acceptance }`
   → a `PROPOSED` sprint. Stamp every member at creation (`create_task { …, sprintId }`) and **leave
   members in BACKLOG** — under a proposed sprint, BACKLOG is the approval latch, so skip the usual
   READY promotion until the sprint is activated (step 4). Sprint-less plans skip 0 and 4.
1. Decompose the goal into self-contained tasks (`create_task`). **Assume the worker has no other context —
   the ticket fields ARE the brief**, so populate each fully (a title-only task is not allowed):
   - description + **acceptance criteria**; `priority`, `labels`, `requiredCapabilities`;
   - **say which FEATURE each ticket belongs to, now** — you are the only one who knows. Either make
     them subtasks of an epic (`add_subtask` / `parentTaskId`), or put the SAME `feature:<slug>`
     label on every ticket of the feature (`feature:wake-doorbell` — lowercase, hyphenated, one per
     ticket). Chronicle collates a feature's finished tickets into one page from exactly these two
     signals; with neither it falls back to guessing from prose, and a guess is marked as one on the
     published page. One label at planning time costs nothing and is the difference between a
     recorded grouping and an inferred one. Reuse a slug that already exists rather than coining a
     near-duplicate — `auth-collapse` and `auth-mode-collapse` are two features holding half a story
     each, and nothing catches that.
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
   (its task objects take description, context items, attachments, and `blockedBy` edges; a
   top-level `"sprint"` block — `name`/`goal`/`acceptance` — does step 0 and the proposal task of
   step 4 for you).
4. **A sprint plan ends through the human.** Create the proposal task ("Sprint plan: <name>",
   `customFields: { sprintProposalFor: "S-…" }`, not itself a sprint member), bind it with
   `update_sprint { patch: { proposalTaskId } }`, and complete it with the full plan as its
   `deliverable` → it lands in **REVIEW** for the human. Then: human approves (REVIEW → DONE) → an
   **admin** activates (`update_sprint { patch: { status: "ACTIVE" } }` — server-refused until the
   bound proposal task is DONE; the proposer cannot self-activate) → promote the members
   BACKLOG → READY (`move_task`). Rejected instead? The reviewer's `add_follow_up { reopen: true }`
   is the correction loop — revise and re-complete.

Follow the batondeck-worker skill (the *Sprints* section has the full flow). Goal: $ARGUMENTS

---
description: Work the tickets assigned to you — drain your BatonDeck inbox by agent name.
---

Work every ticket the board has routed to **you** (the task's `assignee` = your agent name) on BatonDeck,
over MCP. BatonDeck is pull-based — you pick up assigned work when prompted; nothing is pushed.

Inputs: $ARGUMENTS — your agent name (the exact `x-batondeck-agent` value humans assign to), and
optionally the project/board. If you don't know the project/board, discover them first with
`list_projects` → `list_boards`.

Loop until your inbox is empty:

1. **Find your work:** `next_task { projectId, boardId, assignee: "<your-name>" }` — the highest-priority
   READY ticket routed to you, or `null` → stop. (`wait_for_task { …, assignee }` is the long-poll variant
   if you'd rather block briefly for one to arrive.)
2. **Claim it:** `claim_task { projectId, taskId }` → save the `leaseId`. Assignment is **advisory** — if you
   lose the race (`CONFLICT_LOCKED`), skip it and fetch the next.
3. **Load context:** `get_task_context { projectId, taskId, includeUpstream: true }` and **use every populated
   section** — `field`/`decision`/`note` items, `memory` (durable facts), `attachments` (download via
   `downloadUrl` and work from the designs/specs), `upstream` deliverables (build directly on them), and
   **`openFollowUps`** (directives aimed at the holder you must satisfy).
   **If a handoff note is present, treat it as additional instructions.**
4. **Decide processable or not:**
   - **Processable** → first **clear open follow-ups**: for each entry in `openFollowUps`
     (`openFollowUpCount` is the quick check) do what the directive says, record it, then
     `ack_follow_up { projectId, taskId, followUpId }`. Then do the work, recording as you go
     (`add_context_item`, `write_memory`, `set_summary`), `heartbeat_task` before the lease expires —
     re-checking `openFollowUps` on each heartbeat and clearing any new directive — then
     `complete_task { leaseId, deliverable }` (always pass a `deliverable`). Completing auto-unblocks dependants.
   - **Not processable** (out of your scope / needs a human or another agent) → say so in the terminal, record
     why on the ticket with `add_context_item { type: "note", … }`, then `handoff_task` or `block_task` as
     appropriate (don't silently drop it).
5. **Repeat from step 1** until `next_task` returns `null`.

A ticket the board re-routes to you as READY after you'd completed it (or one carrying a `task.reopened`
event) is a reviewer requesting changes via a follow-up — re-claim it, address the new `openFollowUps`, ack
them, and re-complete. Reopened work is a correction loop, not a failure.

Follow the `batondeck-worker` skill for the full working loop and rules. Agent (and optional project/board):
$ARGUMENTS

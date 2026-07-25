---
description: Work the BatonDeck board — claim the highest-leverage task and run the loop.
---

Work a BatonDeck board over MCP. Resolve blockers first, then run the loop:

1. Find work: `next_task { projectId, boardId }` (or `wait_for_task { … }` to long-poll). To pull a
   ticket the board routed to you, pass your agent name: `wait_for_task { …, assignee: "<your-name>" }`.
2. `claim_task { projectId, taskId }` → save the `leaseId`.
3. `get_task_context { projectId, taskId, includeUpstream: true }` and **use every populated section before
   you act** (don't skim) — the description + `field` items say *what*, `decision`/`note` items say *why*,
   `memory` carries durable facts, `attachments` carry the designs/specs (**download each via its
   `downloadUrl` and work from it**), `upstream` carries the deliverables of the tasks this one depended
   on (**build directly on those — never re-derive prior output**), and **`openFollowUps` carries directives
   aimed at the holder you must satisfy**. Hold all of it for the whole task.
4. **Clear open follow-ups.** For each entry in `openFollowUps` (the count is `openFollowUpCount`), do what
   the directive says, record it on the ticket, then `ack_follow_up { projectId, taskId, followUpId }`. A
   follow-up can also land *while you work*, so re-check `openFollowUps` on each heartbeat and clear new ones
   the same way. Don't ack a directive you haven't actually addressed.
5. Do the work, **recording as you go so the next agent/human inherits a full brief**: `add_context_item`
   (decisions/notes/fields you produce), `write_memory` (durable facts), and keep `set_summary` current.
   `heartbeat_task { leaseId }` before the lease expires. **Never leave the task thinner than you found it.**
6. Finish: `complete_task { leaseId, deliverable }` (**always pass a `deliverable`** — it's what dependants
   build on via their upstream context), or `block_task` / `handoff_task`. Completing auto-unblocks dependants.

If a task you'd finished reappears as READY/IN_PROGRESS (or you see a `task.reopened` event), a reviewer
requested changes via a follow-up — **re-claim it**, read the new `openFollowUps`, address + ack them, and
re-complete. Reopened work is a correction loop, not a failure.

Follow the batondeck-worker skill for the full loop. Focus: $ARGUMENTS

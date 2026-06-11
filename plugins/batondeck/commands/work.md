---
description: Work the BatonDeck board — claim the next task, do it with full context, complete or hand off, repeat.
---

Use the batondeck-worker skill. Run the worker loop against the connected BatonDeck MCP server:
prefer `wait_for_task` long-polling to pick up work the moment it becomes READY, `claim_task` it,
load `get_task_context`, do the work, heartbeat the lease while working, then `complete_task`
(or `block_task` / `handoff_task` with a memory note). Repeat until the board is drained or I stop you.
$ARGUMENTS

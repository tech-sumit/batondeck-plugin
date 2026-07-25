---
description: Go off shift — disarm BatonDeck worker/master mode and end the loop cleanly.
---

Take this session off shift:

1. **Disarm:** run `"${CLAUDE_PLUGIN_ROOT}/scripts/mode.sh" off` (the Stop gate stands down).
2. **Leave nothing orphaned:** if you hold a lease, finish the ticket or `release_task` /
   `handoff_task`, and record where things stand on the ticket (`add_context_item`, `set_summary`)
   so the next holder inherits a full brief.
3. **Shift report:** print a short summary — tickets completed / reviewed / blocked this shift, and
   the board's current frontier (what's READY, what's stuck).

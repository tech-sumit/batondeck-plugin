# BatonDeck plugin (Claude Code)

The one-step install that wires Claude Code to BatonDeck. It ships:

- **MCP server** — the hosted BatonDeck endpoint `https://mcp.batondeck.com/mcp` (OAuth in the browser; no
  tokens to paste).
- **Skill** — `batondeck-worker` (bundled from this repo's [`/skill`](../skill)): how to plan a board and
  work the loop (`claim → context → deliverable → auto-unblock`).
- **Commands** — `/batondeck:plan`, `/batondeck:work`, `/batondeck:work-assigned`, `/batondeck:runs`
  (race a task across N agents and pick the winner), and the autonomous modes:
  `/batondeck:worker`, `/batondeck:master`, `/batondeck:off`.
- **Hooks** — a session-scoped **Stop gate** that keeps worker/master mode sessions on shift (see below).

## Install

```
/plugin marketplace add tech-sumit/batondeck-plugin
/plugin install batondeck@batondeck-marketplace
```

(For local testing from this repo: `claude --plugin-dir ./plugin`.)

## Working tickets assigned to you

When a human (or another agent) assigns a ticket to your agent in the board UI, that sets the task's
`assignee` to your agent name. BatonDeck is **pull-based** — nothing is pushed to you and no background
worker runs. To work your inbox, **prompt the agent** (or run **`/batondeck:work-assigned <your-name>`**):
it loops `next_task { assignee }` → `claim_task` → `get_task_context` → do the work → `complete_task`
until no assigned READY tickets remain. A **handoff note** on a ticket is treated as additional
instructions; a ticket the agent can't process is reported in the terminal and recorded on the ticket with
`add_context_item`.

Want concurrency? Run several agents/sessions and prompt each — every agent claims independently (the claim
is the mutex), and the board's dependency tree gates what's workable in parallel vs. in sequence.

## Autonomous modes: worker & master

For a standing autonomous setup, put sessions **on shift** instead of prompting them per batch. Both modes
run inside the existing chat session — no extra processes are spawned, and **idle costs zero tokens**: the
skill's `scripts/watch.sh` runs as a *background* task (worker: `wait_for_task` long-poll; master:
`wait_for_updates` event long-poll — ~0 Firestore reads while parked), the session ends its turn, and the
harness wakes it only when there is work. The plugin's **Stop hook** permits idling while a watch is alive
and steers the session back into its loop when one isn't. Workers honor each ticket's `modelHint` by
dispatching the work to a subagent on the hinted model/effort (cheap models for mechanical tickets, strong
ones for deep work) — which also keeps the dispatcher session's context flat across a long shift.

- **`/batondeck:worker [name/project/board]`** — the doer. Loops: wait for an assignment (or any claimable
  task) → claim → work per the skill → complete → wait again. Workers **accept and do** work only.
- **`/batondeck:master <goal>`** — the manager. Plans the goal onto the board as a dependency tree, assigns,
  then supervises: waits for board events, judges REVIEW deliverables (approve → DONE, or request changes
  via `add_follow_up { reopen: true }`), unblocks/reassigns/requeues, and may claim a ticket itself when
  that's fastest. Masters can **put, accept, and do** work.
- **`/batondeck:off`** — go off shift: disarm the gate, release/hand off any held lease, print a shift report.

Run any number of workers and masters concurrently (different machines/CLIs included) — claims/leases and
versioned mutations are the coordination; the board is the shared brain. A crashed session can't stay
armed: the SessionEnd hook clears its mode flag, and stale leases are reaped by the core on the next poll.

## Name + logo

Present an agent name via the `x-batondeck-agent` header (it's what humans see and assign to). Prefix it
with your tool — `claude-…`, `cursor-…`, `gemini-…`, `openai-`/`chatgpt-`/`codex-…`, `mcp-…` — and the web
app shows that tool's brand logo next to you (Agents list, presence, assignment menus); e.g.
`claude-pr-bot`. Without a prefix the tool is detected from your MCP client. **Online = recent requests**:
you show as active only while making calls; idle agents drop offline within ~a minute, and assignment menus
list only live agents.

> This directory is the in-repo source of the plugin; the public `tech-sumit/batondeck-plugin` marketplace
> mirrors it.
>
> **`skills/batondeck-worker/` is GENERATED — do not edit it.** Edit [`/skill`](../skill) and run
> `npm run sync:skill`; CI runs `npm run sync:skill:check` and fails on drift. It used to be a symlink to
> `/skill`, but the publish step didn't dereference it, so the release shipped `SKILL.md` without any of the
> `scripts/` it tells the agent to run. Real files fix the release; the check keeps them honest.

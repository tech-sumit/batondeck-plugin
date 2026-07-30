# Parallel delivery: running a fleet against one repo

The board tells you *what* can run concurrently (the frontier — see **Run multiple agents** in
SKILL.md). This file is the other half: how several agents change the *same repository* at once
without corrupting each other's work, and how what they produce gets verified before it lands.

Everything here is learned behaviour. Each rule prevents a failure that actually happened.

---

## 0. Project setup: what a repo needs before lanes run against it

Five prerequisites. The first is hard; the rest are the practice the rest of this file details.

1. **Git is required.** No git, no branch, no resumability — a lane that cannot commit cannot be
   resumed by anyone but a human sitting at that machine.
2. **A remote is optional, but it changes the guarantee — say which you have.** *With* a remote,
   pushed work survives the machine and any agent anywhere can `git fetch` and resume the lane.
   *Without* one, resumability is **same-machine only**: still a large win over losing the work, but
   do not describe it as more than it is. Either way the ticket stays auditable — `add_artifact`
   takes commit shas and repo-relative paths when there is no forge URL to give.
3. **One worktree per lane, fenced by directory.** What bounds concurrency is **file overlap, not
   agent count** (§2).
4. **Re-run the gate in the MAIN checkout, on the merge result.** A green gate inside a worktree
   proves nothing about the integration branch (§3).
5. **Remove worktrees once their branch merges.** They are full checkouts and they change how
   repo-scanning tooling behaves (§1).

## 1. One isolated checkout per ticket

Two agents editing one working tree will clobber each other — one `git checkout` or a stray
`git add -A` and the other's work is gone. Give each concurrent ticket its **own git worktree**
(or its own clone; a container works too):

```
git worktree add ../work-T-42 -b feat/t42-<slug> origin/main
```

**First, check whether this lane already has work.** `get_task_context { projectId, taskId }` — if the
ticket carries a **`branch` artifact**, a previous agent already worked it and the branch is where
their commits live:

```
git fetch origin && git checkout <branch>        # RESUMING — continue from the ticket's NEXT
```

**Only when there is no `branch` artifact** is this a genuine start, and only then do you reset:

```
git fetch origin && git reset --hard origin/main # STARTING — no predecessor to lose
```

Getting these two backwards is not a style question. `reset --hard origin/main` on a resumed lane
**destroys every commit the predecessor made**, and it is the reflex the whole surrounding convention
trains — this file said it unconditionally until 2026-07-29. Check for the artifact first, every time.

Agent worktrees routinely start dozens of commits stale — including behind the very conventions the
agent is about to be judged against. That is what the fresh fetch is for; it is not a reason to
discard a predecessor's branch.

**Clean them up when the branch merges.** Stale worktrees are not free: they are full checkouts, and
tooling that scans upward or outward from the repo root (linters resolving a project config, type
checkers, test discovery) can see N copies of everything and behave differently — or fail outright —
in the main checkout while passing inside each worktree.

## 2. Concurrency is bounded by file overlap, not by agent count

The board's frontier says five tickets *may* run. Whether they *should* depends on what they touch.

- Tickets fenced to different directories run cleanly in parallel.
- Two tickets in the same module will spend more time rebasing than working.

So **write the fence into the ticket**: state in the brief which paths the ticket owns
(`add_context_item { kind:"decision" }` is a good place for it). When a ticket genuinely spans
layers, say so and expect it to rebase — `main` moves under long work. Sequence overlapping tickets
with a dependency edge (`add_dependency`) instead of racing them; that is what the dependency graph
is for, and the server will auto-unblock the second when the first is DONE.

Rule of thumb: **parallelise by directory, serialise by file.**

## 3. A gate that runs in the worktree proves nothing about main

This is the subtle one, and it is expensive.

An agent working inside an isolated checkout cannot see the state of the integration branch. A build,
lint or test that passes there can fail the moment the change is merged — because of a neighbouring
branch's change, because tooling behaves differently outside the isolated tree, or because the
isolation itself hides the fault.

Real case: a repo's linter failed with **1041 errors in the main checkout** while passing inside every
agent worktree, because the tool discovered one project config per worktree and refused to run. Six
tickets were completed and reported "gate green". None had ever run the gate that mattered.

**So: whoever merges re-runs the full gate in the integration checkout, on the merge result.** Not the
author, not in the worktree, not before the rebase. If your project has a pre-push or CI gate, that is
the artifact to trust — and never bypass it (`--no-verify`, skip flags) to get a ticket to DONE.

## 4. Review is adversarial, and it is where the real bugs are

`complete_task` hands a ticket to a reviewer (see **Work a task** in SKILL.md). Treat that reviewer as
a skeptic, not a rubber stamp:

- **Disbelieve the deliverable.** Re-run one of its proofs yourself. "The tests pass" is evidence they
  ran, not evidence they test anything.
- **Attack what the author disclosed.** A good deliverable states what it did *not* verify — that list
  is your work queue, not a formality to skim.
- **Check the artifacts, not just the prose.** `get_task_context` plus the ticket's `artifacts[]` is
  the audit trail; a deliverable naming a commit as bare text is not reachable evidence.
- **Never approve your own work.** The identity that completed a ticket should not be the one that
  moves it to DONE — the server flags this, and rejects it outright under
  `selfApprovalPolicy:"enforce"`.

### The bugs that only exist after the merge

The highest-value finds are not in any single ticket. They appear when two correct changes meet:

- a validation written for three enum values, still passing, after a fourth was added elsewhere —
  which silently exposed private data;
- a numeric cap in one change that made a legitimate input from another change unrepresentable;
- a *second* code path to the same outcome that a new policy check never learned about, so the policy
  was bypassable by taking the other route.

None of these is visible in a per-ticket review. When several tickets land together, explicitly ask:
**what did each change assume that another change just made false?** Regenerate anything generated
(schemas, specs, docs) rather than hand-merging it, and re-check any list that enumerates the system's
surface — a new capability that nothing classified is a hole.

## 5. Bind the evidence before you complete

Record what the work produced *before* `complete_task`, not after — the agent that did the work is the
one that forgets, and a completed ticket with no artifact is unauditable forever after.

```
bash scripts/artifacts.sh [pr-url]     # prints the artifacts array for the current checkout
```

It reads the local VCS only (no auth needed), derives the forge from the remote, and records the PR
URL and the branch as **separate** entries — they answer different questions. With no remote it falls
back to commit SHAs and repo-relative paths, so local-only work is still auditable.

Pass the array to `add_artifact`, or inline as `artifacts` on `complete_task`. Then audit the board
with `list_tasks { status:"DONE", missingArtifacts:true }` — on a healthy board, for new work, that
list is empty.

## 6. Choosing the orchestration shape

| Situation | Shape |
|---|---|
| A burst of known, independent tickets | **Inline orchestration** — one session spawns a worktree agent per ticket, then reviews and merges centrally. Simplest thing that works; the reviewing session keeps the whole picture. |
| Work arriving over time, unknown shape | **Master + workers** — a master plans and supervises live board events, workers wait for assignments. Both idle at ~0 reads. |
| One expensive, ambiguous ticket | **Runs** — race N attempts and pick a winner (`start_runs` → `list_runs` → `pick_run`). |
| A ticket that fans out into children | **`orchestrate_subtasks`** + `wait_for_children` — creates the children, parks the parent at ~0 reads, wakes it when the last child is DONE. |

Do not reach for a standing autonomous mode when a single supervised burst will do. Modes are for
duration, not for parallelism — the board provides the parallelism either way.

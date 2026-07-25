# BatonDeck tool reference

Connect over Streamable HTTP at the core's `/mcp` endpoint
(`https://conductor-core-hn5syhhsja-el.a.run.app/mcp` for the hosted instance) with an
`Authorization: Bearer <Google ID token>` header whose audience is the core URL. The core is public
and self-enforces auth (OAuth 2.0 Protected Resource Metadata at
`/.well-known/oauth-protected-resource`, RFC 9728; `401` carries a `WWW-Authenticate` challenge). See
[`../SKILL.md`](../SKILL.md) for the full connection + token-minting recipe.

All tools take an explicit `projectId` (checked against your membership). Mutations take the
expected `version` (and `leaseId` where a lease is required) and return the new `version`.
Errors use stable codes (SRS §10): VALIDATION, UNAUTHENTICATED, FORBIDDEN, NOT_FOUND, STALE,
CONFLICT_LOCKED, LEASE_EXPIRED, INVALID_TRANSITION, WIP_EXCEEDED, CYCLE_DETECTED, QUOTA_EXCEEDED,
RATE_LIMITED, INTERNAL.

## Discovery / admin
- `list_projects {}` → projects you're a member of.
- `get_project { projectId }`
- `create_project { name }` — you become admin.
- `add_member { projectId, identityId, role }` / `remove_member { projectId, identityId }` (admin)
- `create_board { projectId, name, columns? }` / `add_column { projectId, boardId, name, status, wipLimit? }`
- `list_boards { projectId }` / `get_board { projectId, boardId }`

## Tasks
- `create_task { projectId, boardId, title, modelHint?, ... }` — `modelHint { model, effort?, rationale? }` is the creator's complexity estimate (model id or size class + `low|medium|high|xhigh` effort) the worker must honor; advisory, schema-validated only. Lands the task in the board's **first column (BACKLOG)**. BACKLOG tasks are **NOT claimable** and are **invisible to `next_task`/`claim_next`**, and nothing auto-promotes them (auto-unblock only fires on `BLOCKED`). After creating (and wiring dependencies), **`move_task { toStatus: "READY" }`** — promote *every* task, not just leaves; a READY task with a non-empty `blockedBy` is simply excluded from selection until auto-unblock empties it.
- `get_task { projectId, taskId }` / `list_tasks { projectId, boardId, status?, assignee?, label?, unblockedOnly?, missingArtifacts?, limit?, cursor? }` — `missingArtifacts:true` + `status:"DONE"` is the audit query: finished tickets carrying no evidence
- `update_task { projectId, taskId, version, patch }` — `patch.modelHint` sets/replaces the hint; `modelHint: null` clears it.
- `move_task { projectId, taskId, version, toColumnId? | toStatus?, order? }` — `BACKLOG → READY` is the promotion that makes a created task workable.
- `add_context_item { projectId, taskId, kind, body }` / `set_summary { projectId, taskId, version, summary }`
- `add_comment { projectId, taskId, body, parentCommentId?, idempotencyKey? }` → `{ comment }` — threaded markdown comment; `@mentions` of project members are resolved + recorded (notifies them). `parentCommentId` replies to another comment. / `list_comments { projectId, taskId, limit?, cursor? }` → `{ comments, nextCursor? }` (oldest-first)
- `add_artifact { projectId, taskId, artifacts:[{ kind:"pr"|"branch"|"commit"|"file"|"doc"|"attachment", url?, ref?, repo?, title? }], version? }` → `{ task, added }` — bind produced work to the ticket. `pr` and `branch` are SEPARATE entries by design (what was reviewed vs where the work lives). Forge-agnostic (GitHub/GitLab/Bitbucket/Gerrit/hg); with no remote, record `commit` shas + repo-relative `file` paths. Append-merged and de-duplicated, so retries are safe; `version` is optional (supplied → `STALE` on mismatch). Shell: `bash scripts/artifacts.sh [pr-url]` prints the array for the current checkout (local VCS only — no auth).
- `list_notifications { limit?, cursor? }` → `{ notifications, unread, nextCursor? }` — YOUR in-app notifications (newest-first, cross-project; v1 = @mentions). / `mark_notifications_read { ids? | all? }` → `{ updated }`

## Lifecycle (leases)
- `claim_task { projectId, taskId, leaseSeconds? }` → `{ leaseId, task }`
- `claim_next { projectId, boardId, capabilities?, assignee?, useProfile?, leaseSeconds?, shard?:{index,count}, maxConcurrency? }` → `{ leaseId, task, attempts }` — **select AND claim** the best eligible task in one server-side op; falls through to the next candidate on a collision (concurrent workers never pick-then-collide), returns the first won or `{task:null}` when drained. `shard` stripes the frontier into disjoint lanes; `maxConcurrency` caps the caller's live claims (→ `RATE_LIMITED`); `useProfile:true` matches against your registered profile and defaults the ceiling to its maxConcurrency. Prefer over `next_task`+`claim_task` in wide fleets.
- `heartbeat_task { projectId, taskId, leaseId }` / `release_task { ... leaseId }`
- `complete_task { ... leaseId, deliverable?, artifacts? }` → `{ task, warnings? }` — pass `deliverable` (result/summary or link) so unblocked tasks can build on it via `includeUpstream`; it's stored on the ticket. `artifacts` binds the evidence in the same call (same shape as `add_artifact`, merged + de-duplicated). Completing with NO artifact returns a `warnings` entry, or is rejected (`VALIDATION`) on a project set to `artifactPolicy:"enforce"`; label a ticket `no-artifact` when it genuinely produces none. On a reviewing board the ticket is HANDED OVER: `reviewer` (an agent name or human identity; else the ticket's `reviewer`, else `settings.defaultReviewer`) is recorded in `task.review`, made the assignee and notified, and your lease is released — the response returns `handover: { reviewer, status }` so you can sign off in the terminal / `block_task { ... leaseId, reason, blockedBy? }`
- `fail_task { projectId, taskId, leaseId, reason, retryable? }` → `{ task }` — report a CLAIMED task failed (T-4): drops the lease, increments `claimAttempts`, and either schedules a backed-off retry (→ READY, selectable only after the exponential backoff) or quarantines it (→ `DEAD_LETTER`) when `retryable:false` or past the project poison threshold. Use this instead of abandoning a lease so the failure is counted + backed off fleet-wide.
- `requeue_task { projectId, taskId }` → `{ task }` — un-quarantine a `DEAD_LETTER` task (→ READY, `claimAttempts`/backoff reset). Writer role; INVALID_TRANSITION on a non-quarantined task.
- `reap_stale_leases { projectId, boardId }` → `{ reaped }` — force the dead-lease sweep (flip expired-lease IN_PROGRESS tasks → READY-with-backoff or DEAD_LETTER). Happens automatically on next_task/wait_for_task/claim_next/get_board (no background sweeper); call this to force it.
- `handoff_task { ... leaseId, toAgent, memoryNote }`
- `move_task { projectId, taskId, version, toColumnId?, toStatus?, order? }` → `{ task, warnings? }` — REVIEW → DONE is an APPROVAL: the identity that completed the task must not be the one approving it, so a self-approval is flagged in `warnings` (default) or rejected with `FORBIDDEN` under `selfApprovalPolicy:"enforce"`.
- `next_task { projectId, boardId, capabilities?, assignee?, strategy?, explain?, useProfile? }` — highest-priority claimable READY task (or null). Pass `assignee` to pull only tickets the board routed to that agent name. `strategy:"score"` (or `explain:true`) ranks by a cost-aware scorer (priority · deadline · bottleneck fan-out · capability fit · bounded aging) instead of FIFO-priority; omit for the legacy order. `useProfile:true` matches against your registered capability profile (exact · alias · tag) and breaks near-ties by your reliability. `explain:true` adds the per-factor breakdown + runner-up (+ tier/reliability under useProfile).
- `rank_tasks { projectId, boardId, capabilities?, assignee?, useProfile?, limit? }` → `{ ranked: {task, score, reason, agedOut, factors, tier?, reliability?}[] }` — read-only explainable ranking of the claimable pool (zero extra reads); see *why* work is ordered. `useProfile:true` ranks against your capability profile.
- `wait_for_task { projectId, boardId, capabilities?, assignee?, timeoutSec? }` — long-poll `next_task`: blocks until a claimable task appears (default 25s, max 50s; `{task:null}` on timeout), re-call in a loop. With `assignee`, it's your **board-assignment inbox** — wakes only on tickets assigned to that name. Then `claim_task` the result.
- `wait_for_updates { projectId, boardId, sinceCursor?, timeoutSec?, limit? }` → `{ events, cursor }` — long-poll the board **event feed** (the supervisor-side companion to `wait_for_task`, and what the gateway drives the human live-UI push from; ~0 reads while idle). First call WITHOUT `sinceCursor` returns the current `cursor` immediately; then re-call with it in a loop — blocks until events after the cursor land (task transitions, follow-ups, …; **oldest-first**, a burst larger than `limit` drains over successive calls) or timeout (`{events:[]}`, cursor unchanged). The `cursor` is an opaque `ts|id` token — same-millisecond siblings are ordered deterministically so none are dropped. Use instead of polling `list_tasks` to watch a board.

## Agent capability registry (T-3)
- `register_agent_profile { projectId, capabilities, tags?, maxConcurrency?, costClass? }` → `{ profile }` — register what YOU (this agent) can do, server-side, so selection stops relying on a capability list you re-declare every poll. Keyed by your agent name. `tags` are broad coverage areas (a tag covers a required capability as a weaker, penalized match); `maxConcurrency` becomes the default `claim_next` ceiling. Then pass `useProfile:true` to next_task/claim_next/rank_tasks. Re-registering overwrites in place.
- `get_skill_stats { projectId, agentKey? }` → `{ profile, stats }` — an agent's profile + per-(capability) outcome stats: completions, blocks, a regularized `reliability` (low-sample floor → newcomers read neutral, never 0), and a mean handle time. Omit `agentKey` for your own; pass one to inspect another. Stats accrue automatically from `complete_task`/`block_task` on tasks that declare `requiredCapabilities`.
- Admins set capability synonyms via `update_settings { projectId, capabilityAliases: { "py-test": "pytest" } }` so aliases match at full (synonym) tier.

## Context / graph / media
- `get_task_context { projectId, taskId, include?, includeUpstream?, limit?, cursor? }` → also returns this task's `deliverable` and `modelHint`, plus `openFollowUps[]` (bounded) + `openFollowUpCount` — outstanding directives for the holder, **act on each then `ack_follow_up`**; with `includeUpstream:true`, an `upstream[]` of the deliverables (+title/status/summary) of the tasks it depended on — set it on any task unblocked by others and build on those outputs. Also returns **`workflow { status, allowedMoves, lanes }`** — the board's lane structure and the exact statuses `move_task` will accept next from this task's current status, so you can pick a legal move without provoking an `INVALID_TRANSITION` (and if you do hit one, its message names the allowed moves + the legal path anyway).
- `write_memory { projectId, taskId?, scope, key, value? | largeArtifact?, ttl? }` / `read_memory { projectId, taskId, scope?, key? }` — scopes `task`/`agent`/`shared` hang off the task and die with it (`taskId` required).
- **Durable memory** — `scope: 'project'` (a fact every member should reuse: "the staging deploy token lives in Secret Manager under X") or `scope: 'agent_global'` (private to you, follows you across every project: "this client always wants British spelling"). Both are stored away from the task, so they survive it; `taskId` is optional there. Read them back with `recall_memory { projectId?, scope?, key?, k? }` — exact key when you give one, else the most recent `k`. Write the fact ONCE when you learn it, and `recall_memory` at the start of a task instead of rediscovering it.
- `add_dependency { projectId, fromTaskId, toTaskId, type? }` / `remove_dependency { projectId, edgeId }`
- `add_subtask { projectId, parentTaskId, title }` / `list_subtasks { projectId, parentTaskId }`
- `attach_file { projectId, taskId, fileName, mimeType, kind, bytes }` → signed PUT URL
- `list_attachments { projectId, taskId }` → manifest + signed GET URLs
- `search_tasks { projectId, query, boardId?, k?, mode? }` → `{ results, mode }`. `mode`: `keyword` (literal terms), `semantic` (by MEANING, over embedded summaries/deliverables/notes/shared memory/attachment OCR text), `hybrid` (default — reciprocal-rank fusion of both). **Before solving anything, ask the board whether it was solved already**: `search_tasks { query: "how did we handle the OAuth refresh edge case" }` finds the completed ticket even when it never used those words. The returned `mode` is the one that actually ran — it reads `keyword` when the workspace has embeddings disabled.

## Follow-ups (directed, actionable instructions to the holder)
A **follow-up** is a directive aimed at the task's current holder (lease owner/agent, else the assignee) — distinct from `add_comment` (open discussion) and `handoff_task` (reassignment). It notifies the target, surfaces in `get_task_context.openFollowUps`, and can optionally **reopen** a REVIEW/DONE task (the "request changes" loop).
- `add_follow_up { projectId, taskId, body, reopen?, idempotencyKey? }` → `{ followUp, task }` — writer role. Records the directive (markdown `body`), notifies the resolved `target`, appends `task.follow_up`. With `reopen:true` and task ∈ {REVIEW, DONE}, transitions it back to IN_PROGRESS (holder/assignee present) or READY, bumps `version`, appends `task.reopened`; a reopen requested from any other status is a recorded no-op.
- `ack_follow_up { projectId, taskId, followUpId }` → `{ followUp }` — the holder marks a directive acknowledged (`status:'acked'`), appends `followup.acked`. Ack each open directive **after** acting on it.
- `list_follow_ups { projectId, taskId, openOnly?, limit?, cursor? }` → `{ followUps, nextCursor? }` — bounded, chronological; `openOnly:true` for just the outstanding ones.

## Runs (race a task across N agents, pick the winner)
A **run** is a normal claimable child task linked to its parent by `runOf` (distinct from decomposition subtasks). A lead/orchestrator opens a race for high-stakes/ambiguous work; workers claim/work/complete runs like any task; the lead later **picks** the winning run (its deliverable is promoted onto the parent) and the losers are cancelled. The racing **parent** is non-claimable (`racing:true`) while the race is open. Capped per parent by `maxRunsPerTask`.
- `start_runs { projectId, taskId, version, count?, agents?, brief? }` → `{ task, runs }` — writer role. Opens a race on a READY/BACKLOG parent (or one IN_PROGRESS held by the caller): sets the parent `racing:true`, then creates `count` (or `agents.length`) run children (each `runOf:taskId`, status READY, copied brief/labels/capabilities, `assignee: agents[k] ?? null`).
- `open_run { projectId, taskId, agent?, brief? }` → `{ run }` — add one more run to an already-racing parent (let another agent join late).
- `list_runs { projectId, taskId }` → `{ runs }` — bounded query of this parent's runs; each `{ taskId, status, assignee, leaseHolder, hasDeliverable, deliverable?, version }`. Compare runs here before picking.
- `pick_run { projectId, taskId, runTaskId, version }` → `{ task }` — writer/admin. The chosen run must be submitted (REVIEW/DONE with a `deliverable`). Promotes the run's deliverable onto the parent, clears `racing`, advances the parent (REVIEW if review enabled, else DONE), cancels every other run (releasing their leases), and auto-unblocks the parent's real dependents if it reached DONE.
- `cancel_runs { projectId, taskId, version }` → `{ task }` — abandon the race: parent back to READY (`racing:false`), all runs → CANCELLED.

Reused unchanged for the actual work inside a run: `claim_task`/`claim_next`, `heartbeat_task`, `release_task`, `complete_task` (sets the run's `deliverable`), `get_task_context`.

## Resources (subscribe for live updates)
- `conductor://{projectId}/board/{boardId}` · `.../task/{taskId}` · `.../task/{taskId}/context` · `.../board/{boardId}/feed`

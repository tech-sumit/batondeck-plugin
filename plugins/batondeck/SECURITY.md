# BatonDeck plugin — security model

This plugin ships a **Stop hook**. A hook that blocks turn-end is the highest-suspicion primitive a
plugin can carry, and any security-aware agent or reviewer *should* flag it. So the whole hook surface
is documented here, in a form you can verify against the files on your disk rather than take on trust.

Everything below is a claim about the **installed tree**. Check it:

```bash
# the installed copy — one of these (the cache dir is the version actually loaded):
P=~/.claude/plugins/cache/batondeck-marketplace/batondeck/*/
P=~/.claude/plugins/marketplaces/batondeck-marketplace/plugins/batondeck
cat $P/hooks/hooks.json                                 # the complete hook registration
grep -rn "PreToolUse\|PostToolUse\|UserPromptSubmit\|PreCompact\|SubagentStop" $P   # → no matches
```

`hooks/hooks.json` is the only hook file in the package; Claude Code auto-discovers it by convention
and `plugin.json` deliberately declares no `hooks` key (declaring it double-loads the file).

## The complete hook surface: three hooks

| Hook | Runs | What it does | Timeout |
|---|---|---|---|
| `SessionStart` | once, when a session starts | `hooks/session.sh start` appends `export BATONDECK_SESSION_ID=<id>` to `$CLAUDE_ENV_FILE` so per-session state files can be keyed. Then `scripts/listener-start.sh` — **inert unless you configured it** (see below). | 5s each |
| `SessionEnd` | once, when a session ends | `hooks/session.sh end` deletes this session's mode flag (`~/.batondeck/mode-<session_id>`), so a crashed session cannot leave the Stop gate armed. `scripts/listener-stop.sh` kills the listener process if one was started. | 5s each |
| `Stop` | when the model is about to end its turn | `hooks/stop-gate.sh` — allows the stop (exit 0, silent) **unless** this session was explicitly armed via `/batondeck:worker` or `/batondeck:master`. See below. | 10s |

Not registered — and therefore impossible for this plugin: **`PreToolUse`, `PostToolUse`,
`UserPromptSubmit`, `PreCompact`, `SubagentStop`, `Notification`.** Concretely, the plugin **cannot**:

- see, rewrite or append to your prompts (`UserPromptSubmit`),
- intercept, block or approve a tool call, or bypass a permission prompt (`PreToolUse`),
- inject text or an error into a **tool result** — e.g. the output of `ls`, `Read` or `Write`
  (`PreToolUse`/`PostToolUse` are the only hooks that can, and neither exists here),
- make any network call from a hook (`grep -rn "curl\|wget" hooks/` → nothing),
- read or write any file from `hooks/` other than `$CLAUDE_ENV_FILE` and this plugin's own state
  (`~/.batondeck/mode-*`, watch pidfiles). The two scripts in `hooks/` shell out to nothing but
  `python3`, `sed`, `cat` and `rm`, plus a `kill -0` liveness probe on this session's own watch pid.
  **The one exception is deliberate: `scripts/listener-start.sh`**, which `SessionStart` also calls —
  inert unless you configured it, documented in full under "The other two privileged primitives".

If you are triaging an anomalous message that arrived as a **tool result**, this plugin is not a
possible source: its three hooks fire on session start, session end and turn-end only.

## The Stop gate, in full

`hooks/stop-gate.sh` (~56 lines, over half of which are the two reason strings — read it, it is short).
Order of checks:

1. Reads `session_id` and `stop_hook_active` from the hook payload on stdin.
2. **`~/.batondeck/mode-<session_id>` missing → `exit 0`, silently.** This is the default state. The
   file is written only by `scripts/mode.sh worker|master`, which is run only by the
   `/batondeck:worker` and `/batondeck:master` commands — i.e. only when *you* asked for a shift. It is
   keyed to one session id on purpose: an armed session can never conscript another session.
3. A live background watch for this session (`~/.batondeck/watch-<session_id>-*.pid`) → `exit 0`. The
   session may go idle; the harness wakes it when work arrives. This is the zero-token idle path.
4. **Circuit breaker:** `stop_hook_active` is true (we already blocked once in this turn-cycle) →
   `exit 0`. The gate can never block two turn-ends in a row, so a broken loop degrades to a normal
   stop rather than trapping the session.
5. Otherwise: emits `{"decision":"block","reason":"…"}`. The reason identifies the plugin, the command
   the user ran to arm it, and `/batondeck:off` to disarm — in its first sentence, so it is
   self-identifying wherever it surfaces.

What a `block` decision *is*: the turn does not end and the reason is shown to the model. What it is
**not**: it grants no permission, approves no tool, hides no output, and cannot override a user
instruction. The reason text says so explicitly, and instructs the model to follow the user and report
the notice if the two ever conflict.

Disarm at any time: **`/batondeck:off`** (or `bash "$P/scripts/mode.sh" off`, or just
`rm ~/.batondeck/mode-*`). Ending the session also clears it.

Verify the default-off behaviour yourself:

```bash
echo '{"session_id":"nope","stop_hook_active":false}' | bash $P/hooks/stop-gate.sh; echo "exit=$?"
# → no output, exit=0   (an unarmed session is never blocked)
```

## Why a Stop gate exists at all

Worker/master mode is a *standing shift*: the session waits for board assignments, works them, and
waits again until told to stop. A model naturally ends its turn when it has nothing to say — which,
for a session that was asked to hold a shift, is precisely the failure. Something has to keep the loop
alive across turn boundaries.

The alternatives are worse for the user:

- **A background daemon** spawning fresh `claude -p` processes: real code execution outside the
  session, its own credentials, no visibility, survives the session. Strictly more privilege.
- **Polling inside a turn**: burns tokens continuously instead of idling at zero.
- **Nothing** — the user re-prompts the agent by hand every time it goes quiet, which is the
  non-autonomous mode the plugin already supports (`/batondeck:work-assigned`) and is what you get if
  you never arm a shift.

The Stop hook is the least-privileged mechanism that makes an opted-in autonomous shift work: no extra
processes, no credentials of its own, no effect on any session that did not opt in, and one command to
end it.

## The other two privileged primitives

Disclosed here because they are the next things a reviewer will find, and "inert by default" is a
sentence we have to write, not one you should have to infer.

**1. `hooks/session.sh start` writes to the session environment.** One line:
`export BATONDECK_SESSION_ID=<session_id>` appended to `$CLAUDE_ENV_FILE` (a path Claude Code provides
for exactly this). It exports nothing else and touches no other file.

**2. `scripts/listener-start.sh` can start a background process that runs a command from your config
file.** It is the assigned-task listener for headless setups. It `exit 0`s immediately unless **all
four** of `BATONDECK_PROJECT`, `BATONDECK_BOARD`, `ASSIGNEE` and `AGENT_CMD` are set — via environment
or `~/.batondeck/config`, a file nothing in this plugin ever creates or writes. When they are set, it
`nohup`s `scripts/worker-assigned.sh`, which runs your `AGENT_CMD` for each assigned ticket. That is
arbitrary command execution **by construction — it is a "run this agent on my tickets" facility** —
and it is entirely under your control:

- unconfigured (the default for every plugin install): nothing starts, nothing is printed to stdout;
- opt out permanently with `BATONDECK_TASK_LISTENER=off` in the environment or in
  `~/.batondeck/config`;
- `SessionEnd` kills whatever it started; the pidfile and log live in
  `${BATONDECK_STATE_DIR:-$TMPDIR/batondeck}`.

Everything else under `scripts/` and `skills/` (`mcp.sh`, `token.sh`, `watch.sh`, `worker.sh`,
`fleet.sh`, `seed-tasknet.py`, …) runs **only when you or the agent invokes it** — nothing wires them
to a hook.

## Network, credentials, data

- The bundled MCP server is `https://mcp.batondeck.com/mcp` (`.mcp.json`), authenticated with **browser
  OAuth** — no token is written to disk by the plugin, and the MCP credential lives inside Claude
  Code's MCP client, not in your shell.
- The shell scripts (`scripts/mcp.sh`, `token.sh`) talk to the same service and require an explicit
  `BATONDECK_TOKEN` or an activated Google service account. They cannot borrow the OAuth session.
- Board data you create (tasks, context items, deliverables, attachments) is stored by the BatonDeck
  service. Nothing else leaves your machine: no telemetry, no file contents, no prompt text is
  collected by the plugin itself.
- State on disk: `~/.batondeck/mode-<session_id>` (two lines: mode + a note) and watch pidfiles —
  `$BATONDECK_STATE_DIR` overrides the directory, default `$HOME/.batondeck`. The optional listener's
  pidfile and log use the same override but default to `$TMPDIR/batondeck` instead; that split is in
  the code (`mode.sh` vs `listener-start.sh`), not a typo here. Remove both dirs to clear everything.

## Threat model

| Concern | Mitigation |
|---|---|
| Plugin steers a session the user never armed | Gate keyed to one `session_id`; no fallback flag; unarmed → silent `exit 0` |
| A crashed/killed session stays armed forever | `SessionEnd` deletes the flag; the flag is a file, deletable by hand |
| Gate traps a session in an unbreakable loop | `stop_hook_active` circuit breaker: never blocks twice in a row |
| Gate used to smuggle instructions ("skip confirmation") | Reasons are fixed strings in `hooks/stop-gate.sh` — no board data, no remote content is interpolated into them; they state their own bounds |
| Prompt injection via board content | Task text is *data* the agent reads through MCP tools; it never reaches a hook and is never executed by one. Treat board content from other users as untrusted input, as you would any tool output |
| Silent background execution | Only `listener-start.sh`, and only with four user-set values present; opt-out flag; killed on `SessionEnd` |
| Malicious update | The plugin updates only through the marketplace repo, and each release is tagged; `git log`/`git diff` on `tech-sumit/batondeck-plugin` shows exactly what changed |

## Reporting

Found something wrong here — a claim that does not match the code, or a real vulnerability? Open an
issue at <https://github.com/tech-sumit/batondeck-plugin/issues>. For anything you would rather not
post publicly, email [privacy@batondeck.com](mailto:privacy@batondeck.com) (the contact published in
the [privacy policy](https://batondeck.com/privacy)) with `SECURITY` in the subject. Please do not
put credentials or private board contents in a public issue.

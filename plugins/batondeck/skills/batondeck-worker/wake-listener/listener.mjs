/**
 * The wake channel's EAR: one long-lived Pub/Sub StreamingPull subscriber per Claude Code session.
 *
 * A listener, not a loop (owner, 2026-09-10): it subscribes once and is CALLED per doorbell, for as
 * long as the session lives. It replaces `skill/scripts/wake-listen.py`, which polled REST `:pull` with
 * an empty-backoff sleep and exited on the first message.
 *
 * CREDENTIAL (owner, 2026-09-13): it holds NOTHING of its own. It reads the MCP access token the
 * browser sign-in already stored, exchanges it at Google STS for the session's own subscription, and
 * stops when that token dies — "when renewed by signing in then we serve the updates". There is no
 * refresh loop and no stored long-lived secret, so a leaked listener credential cannot outlive the
 * human's sign-in.
 *
 * Every boundary is injected (`fetch`, the subscriber factory, the clock, the filesystem) so the rules
 * below are testable without a network or a Google project.
 */
import { readdirSync, readFileSync, appendFileSync, mkdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

/** Prod by default; the staging probe and the tests override both. */
export const DEFAULT_MCP = process.env['BATONDECK_MCP_URL'] ?? 'https://mcp.batondeck.com';
export const DEFAULT_CORE = process.env['BATONDECK_CORE_URL'] ?? 'https://conductor-core-hn5syhhsja-el.a.run.app';
/** Overridable so the emulator e2e can drive the real code against a stub; production never sets it. */
export const STS = process.env['BATONDECK_STS_URL'] ?? 'https://sts.googleapis.com/v1/token';
const PUBSUB_SCOPE = 'https://www.googleapis.com/auth/pubsub';

/** A token is usable only if it still has real life left — a 30s sliver buys a stream that dies at once. */
const MIN_LIFE_MS = 60_000;

/**
 * PRESENCE, not polling. `/internal/wake-session` stamps `wakeAttachedAt`, and the UI counts a session
 * attached only while that stamp is under `WAKE_ATTACHED_WINDOW_MS` (360s, `web/src/agentStatus.ts`).
 * A stream held open makes no calls, so without this re-stamp a LISTENING agent fades to "offline" —
 * exactly the bug T-558 fixed. Half the window, so one missed beat does not blink the dot.
 */
export const HEARTBEAT_MS = 180_000;

/** CONSECUTIVE failed re-attaches before the listener stops. Cleared by a delivered doorbell, which
 *  is proof the stream works — so a session running for days survives isolated blips. */
export const MAX_REATTACHES = 5;

/**
 * LIFETIME re-attaches, whatever the successes in between.
 *
 * *** THIS EXISTS BECAUSE CLEARING THE CONSECUTIVE COUNTER REMOVED THE CIRCUIT BREAKER. *** Resetting
 * on a doorbell is right for the case it was written for (five unrelated blips over days should not
 * retire a healthy listener) and wrong for a FLAPPING stream: one that delivers a single message and
 * dies, repeatedly, clears the budget on every cycle and re-attaches forever with no backoff. The test
 * added to prove the reset correct — fail, doorbell, fail, doorbell — is the same test that
 * demonstrates the loop. So the bound moves up a level instead of disappearing.
 */
export const MAX_TOTAL_REATTACHES = 50;

export function claimsOf(jwt) {
  return JSON.parse(Buffer.from(String(jwt).split('.')[1], 'base64url').toString());
}

/**
 * The MCP access token the browser sign-in stored, newest first. Returns null rather than throwing:
 * a missing or unreadable store is a "not signed in" state, never a crashed session.
 */
export function findToken({
  home = homedir(),
  issuer = DEFAULT_MCP,
  now = Date.now,
  fs = { readdirSync, readFileSync },
  env = process.env,
} = {}) {
  // *** T-594 — THE HEADLESS SOURCE, TRIED FIRST. ***
  //
  // This function used to read exactly one place: the store the BROWSER sign-in writes. So the wake
  // listener worked on the interactive OAuth path and NOWHERE else — a worker authenticating with
  // `BATONDECK_TOKEN` had no `~/.mcp-auth`, got `null`, and was told to sign in. Measured consequence
  // on production: 60 of 70 sessions carried a wake subscription and ONE had a listener attached.
  //
  // `BATONDECK_TOKEN` is already a JWS by construction, which is what makes this small: `/mcp`
  // authenticates through `verifyBearer` alone, so a token that can drive `mcp.sh` at all is one STS
  // can exchange. An OPAQUE `bd_` token is a different animal — it 401s at `/mcp`, so it was never a
  // working headless MCP credential, and it is rejected here with its own reason rather than silently
  // read as "not signed in".
  const raw = env['BATONDECK_TOKEN']?.trim();
  if (raw) {
    if (raw.startsWith('bd_')) return { error: 'bd_cli_token' };
    try {
      const c = claimsOf(raw);
      if (c.iss !== issuer || c.knd !== 'access') return { error: 'foreign_token' };
      if (c.exp * 1000 <= now() + MIN_LIFE_MS) return { error: 'expired_token' };
      return { token: raw, exp: c.exp, sub: c.sub };
    } catch {
      return { error: 'unparseable_token' };
    }
  }
  const root = join(home, '.mcp-auth');
  let dirs;
  try {
    dirs = fs.readdirSync(root);
  } catch {
    return null; // no store at all: not signed in
  }
  let best = null;
  for (const d of dirs) {
    let files;
    try {
      files = fs.readdirSync(join(root, d));
    } catch {
      continue; // a stale or unreadable version dir is skipped, never fatal
    }
    for (const f of files) {
      if (!f.endsWith('_tokens.json')) continue;
      try {
        const j = JSON.parse(fs.readFileSync(join(root, d, f), 'utf8'));
        const c = claimsOf(j.access_token);
        if (c.iss !== issuer || c.knd !== 'access') continue;
        if (c.exp * 1000 <= now() + MIN_LIFE_MS) continue;
        if (!best || c.exp > best.exp) best = { token: j.access_token, exp: c.exp, sub: c.sub };
      } catch {
        // A half-written or foreign file is skipped, never fatal.
      }
    }
  }
  return best;
}

/** The core names this session's subscription and the STS audience — no client-side construction. */
export async function wakeSession({ fetch: f, core = DEFAULT_CORE, token, agentId }) {
  const res = await f(`${core}/internal/wake-session`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, ...(agentId ? { 'x-batondeck-agent-id': agentId } : {}) },
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) return { error: `wake-session ${res.status} ${body.error ?? ''}`.trim() };
  if (!body.subscription || !body.audience) return { error: 'wake channel is not enabled for this deployment' };
  return { wpid: body.wpid, subscription: body.subscription, audience: body.audience };
}

/** Exchange the MCP token for Google credentials. The result inherits the MCP token's remaining life. */
export async function exchange({ fetch: f, audience, token }) {
  const res = await f(STS, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      grantType: 'urn:ietf:params:oauth:grant-type:token-exchange',
      audience,
      scope: PUBSUB_SCOPE,
      requestedTokenType: 'urn:ietf:params:oauth:token-type:access_token',
      subjectTokenType: 'urn:ietf:params:oauth:token-type:jwt',
      subjectToken: token,
    }),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) return { error: `sts ${res.status} ${body.error_description ?? body.error ?? ''}`.trim() };
  return { accessToken: body.access_token, expiresIn: body.expires_in };
}

/** One JSON line per event. The session's watcher tails this file; nothing else reads it. */
export function deliver({ file, record, fs = { appendFileSync, mkdirSync }, dir }) {
  if (dir) fs.mkdirSync(dir, { recursive: true });
  fs.appendFileSync(file, JSON.stringify(record) + '\n');
}

export function deliveryFile({ home = homedir(), sessionId }) {
  const dir = join(home, '.batondeck', 'wake');
  return { dir, file: join(dir, `${sessionId || 'default'}.jsonl`) };
}

/**
 * Wire it up. Returns the reason it stopped, so the caller (and the tests) can tell a quiet
 * "nobody is signed in" from a real failure. NEVER throws: this runs from a SessionStart hook.
 */
/**
 * Turn a `findToken` refusal into the line a human can act on. Each reason has a DIFFERENT remedy, and
 * collapsing them into "sign in again" is what sends a headless operator to fix the wrong thing.
 */
export function tokenProblem(reason, issuer) {
  switch (reason) {
    case 'bd_cli_token':
      return `BATONDECK_TOKEN is a bd_ CLI token. Those are opaque, so they cannot drive the MCP endpoint OR the wake channel — use an MCP access token (mcp-remote ${issuer}/mcp) or a WorkOS org API key.`;
    case 'expired_token':
      return 'BATONDECK_TOKEN has expired (or has under a minute left). Re-issue it.';
    case 'foreign_token':
      return `BATONDECK_TOKEN was issued by a different issuer or is not an access token — this listener expects one from ${issuer}.`;
    default:
      return 'BATONDECK_TOKEN is set but is not a readable JWS.';
  }
}

export async function run({
  fetch: f = fetch,
  subscribe,                       // ({ subscription, accessToken, onDoorbell }) => stop()
  sessionId,
  agentId,
  home = homedir(),
  core = DEFAULT_CORE,
  issuer = DEFAULT_MCP,
  now = Date.now,
  log = () => {},
  fs,
  heartbeatMs = HEARTBEAT_MS,
  setTimer = (fn, ms) => setInterval(fn, ms),
  clearTimer = (t) => clearInterval(t),
} = {}) {
  const { dir, file } = deliveryFile({ home, sessionId });
  const say = (record) => deliver({ file, dir, record: { ts: new Date(now()).toISOString(), ...record }, ...(fs ? { fs } : {}) });

  const found = findToken({ home, issuer, now, ...(fs ? { fs } : {}) });
  if (found?.error) {
    // A SUPPLIED-BUT-UNUSABLE token is not the same state as no token, and must not be reported as
    // one: "run mcp-remote" is useless advice to an operator who set BATONDECK_TOKEN deliberately.
    const why = tokenProblem(found.error, issuer);
    say({ event: 'signin-required', reason: why, hint: `npx -y mcp-remote ${issuer}/mcp` });
    log('wake listener idle: ' + why);
    return 'signin-required';
  }
  if (!found) {
    // The owner's model: expiry is a normal idle state with a visible prompt, not an error to retry.
    say({ event: 'signin-required', hint: `npx -y mcp-remote ${issuer}/mcp` });
    log('wake listener idle: no usable sign-in. Run: npx -y mcp-remote ' + issuer + '/mcp');
    return 'signin-required';
  }

  // A network that throws must read as "idle", never as a crashed hook.
  const session = await wakeSession({ fetch: f, core, token: found.token, agentId }).catch((e) => ({
    error: `wake-session unreachable: ${e?.message ?? e}`,
  }));
  if (session.error) {
    say({ event: 'unavailable', reason: session.error });
    log('wake listener idle: ' + session.error);
    return 'unavailable';
  }

  const sts = await exchange({ fetch: f, audience: session.audience, token: found.token }).catch((e) => ({
    error: `sts unreachable: ${e?.message ?? e}`,
  }));
  if (sts.error) {
    say({ event: 'signin-required', reason: sts.error, hint: `npx -y mcp-remote ${issuer}/mcp` });
    log('wake listener idle: ' + sts.error);
    return 'signin-required';
  }

  say({ event: 'listening', wpid: session.wpid, expiresIn: sts.expiresIn });

  let beat;
  let stopSub = () => {};
  let stopped = false;
  let reattaches = 0; // consecutive failures; cleared by a delivered doorbell
  let totalReattaches = 0; // lifetime, never cleared — the hot-loop bound
  const stop = () => {
    stopped = true;
    if (beat) clearTimer(beat);
    return stopSub();
  };

  const attach = (accessToken) =>
    subscribe({
      subscription: session.subscription,
      accessToken,
      onDoorbell: (attributes) => {
        // A DELIVERED DOORBELL IS PROOF THE STREAM WORKS, so it clears the retry budget. Without this
        // `reattaches` is a CUMULATIVE PROCESS-LIFETIME counter: a session running for days across
        // five unrelated transient blips would hit the ceiling and tell a perfectly valid sign-in to
        // sign in again — an alert whose name does not mean what it claims, printing a remedy that
        // cannot help (rule 19). The budget is for a stream that is broken NOW, not for one that has
        // ever hiccupped.
        reattaches = 0;
        say({ event: 'doorbell', kind: attributes?.kind ?? 'unknown', agent: attributes?.agent });
      },
      onError: (reason) => void onStreamError(reason),
    });

  /**
   * *** THE STREAM DYING USED TO LEAVE THIS PROCESS INERT, AND THAT IS THE WORST STATE IT CAN BE IN. ***
   * `onError` wrote one `detached` line and returned: it never stopped, never re-exchanged, never
   * reconnected. The subscriber object stayed open, the heartbeat kept beating, and the agent's session
   * row kept reading "live" — so the core went on publishing doorbells into a stream nobody was reading.
   *
   * AND THE HEARTBEAT CANNOT COVER IT. The beat re-checks the MCP token; the stream is authorized by
   * the STS token exchanged FROM it at startup, which carries whatever life that sign-in had left. A
   * client that refreshes its MCP token therefore keeps the beat green indefinitely while the Pub/Sub
   * credential behind the stream is already dead. The two lifetimes are not the same lifetime.
   *
   * RE-DERIVE, DO NOT RENEW. This re-reads the token from disk and exchanges it again — it mints
   * nothing unattended and needs no new credential path: it uses exactly what the user's own sign-in
   * produced. When that token is gone or expired there is nothing to re-derive from, which is the
   * genuine `signin-required`, and the listener stops loudly instead of pretending.
   *
   * ponytail: bounded attempts, no backoff — a stream failing instantly N times gives up in a burst
   * rather than pacing itself. Upgrade path is a delay before each retry, using the injected
   * `setTimer`. Capped because an unbounded reattach on a permanently-broken stream is a hot loop.
   */
  const onStreamError = async (reason) => {
    if (stopped) return;
    say({ event: 'detached', reason: String(reason) });
    try {
      stopSub();
    } catch {
      // The stream is already dead; failing to close a dead thing is not a failure.
    }
    const giveUp = (why) => {
      say({ event: 'signin-required', reason: why, hint: `npx -y mcp-remote ${issuer}/mcp` });
      log('wake listener stopped: ' + why);
      stop();
    };
    if (reattaches >= MAX_REATTACHES || totalReattaches >= MAX_TOTAL_REATTACHES) {
      // NOT `signin-required` — the sign-in is fine, the STREAM is not, and telling someone to
      // re-authenticate for a broken transport sends them to fix the wrong thing. `unavailable` is
      // the existing vocabulary for "the channel is down, not your credentials", and `wake-wait.mjs`
      // already wakes on it.
      const why =
        reattaches >= MAX_REATTACHES
          ? `stream failed ${MAX_REATTACHES} times in a row: ${reason}`
          : `stream re-attached ${MAX_TOTAL_REATTACHES} times this session (flapping): ${reason}`;
      say({ event: 'unavailable', reason: why });
      log('wake listener stopped: ' + why);
      stop();
      return;
    }
    reattaches += 1;
    totalReattaches += 1;
    const fresh = findToken({ home, issuer, now, ...(fs ? { fs } : {}) });
    if (fresh?.error) return giveUp(tokenProblem(fresh.error, issuer));
    if (!fresh) return giveUp('no usable sign-in to re-attach with');
    const again = await exchange({ fetch: f, audience: session.audience, token: fresh.token }).catch((e) => ({
      error: `sts unreachable: ${e?.message ?? e}`,
    }));
    if (stopped) return; // a concurrent stop() must not produce a second signin-required line
    if (again.error) return giveUp(again.error);
    // *** RE-CHECK AFTER THE AWAIT, OR `stop()` DOES NOT STOP. *** The entry guard is not enough: the
    // heartbeat can fail and call `stop()` while the exchange above is still in flight, and attaching
    // here would then open a NEW live subscriber after the listener has already announced itself
    // stopped — an open StreamingPull nobody holds a handle to, writing doorbells to a delivery file
    // whose last event says `signin-required`.
    if (stopped) return;
    stopSub = attach(again.accessToken);
    say({ event: 'listening', wpid: session.wpid, expiresIn: again.expiresIn, reattached: reattaches });
  };

  stopSub = attach(sts.accessToken);

  // The beat also DETECTS the death the owner's model expects: when the sign-in expires, this call is
  // the first thing to fail, and the session is told to sign in rather than left silently deaf.
  beat = setTimer(() => {
    void (async () => {
      const hb = await wakeSession({ fetch: f, core, token: found.token, agentId }).catch((e) => ({
        error: `heartbeat unreachable: ${e?.message ?? e}`,
      }));
      if (!hb.error) return;
      say({ event: 'signin-required', reason: hb.error, hint: `npx -y mcp-remote ${issuer}/mcp` });
      log('wake listener stopped: ' + hb.error);
      stop();
    })();
  }, heartbeatMs);
  beat?.unref?.();
  return { outcome: 'listening', stop, wpid: session.wpid, file };
}

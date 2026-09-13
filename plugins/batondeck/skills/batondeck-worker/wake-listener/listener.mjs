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

export function claimsOf(jwt) {
  return JSON.parse(Buffer.from(String(jwt).split('.')[1], 'base64url').toString());
}

/**
 * The MCP access token the browser sign-in stored, newest first. Returns null rather than throwing:
 * a missing or unreadable store is a "not signed in" state, never a crashed session.
 */
export function findToken({ home = homedir(), issuer = DEFAULT_MCP, now = Date.now, fs = { readdirSync, readFileSync } } = {}) {
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
  const stopSub = subscribe({
    subscription: session.subscription,
    accessToken: sts.accessToken,
    onDoorbell: (attributes) => say({ event: 'doorbell', kind: attributes?.kind ?? 'unknown', agent: attributes?.agent }),
    onError: (reason) => say({ event: 'detached', reason: String(reason) }),
  });

  // The beat also DETECTS the death the owner's model expects: when the sign-in expires, this call is
  // the first thing to fail, and the session is told to sign in rather than left silently deaf.
  let beat;
  const stop = () => {
    if (beat) clearTimer(beat);
    return stopSub();
  };
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

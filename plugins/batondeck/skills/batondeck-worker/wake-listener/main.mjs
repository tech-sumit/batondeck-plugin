#!/usr/bin/env node
/**
 * Entrypoint: wires the REAL Pub/Sub subscriber into `run()`. Bundled to `plugin/scripts/wake-listener.cjs`.
 *
 * StreamingPull, so this is a listener and not a loop: subscribe once, be called per doorbell.
 * The credentials are STATIC on purpose (owner, 2026-09-13) — the exchanged token carries whatever life
 * the session's sign-in had left, and when it dies the stream ends rather than renewing itself.
 */
import { PubSub } from '@google-cloud/pubsub';
import { OAuth2Client } from 'google-auth-library';
import { run } from './listener.mjs';

function subscribe({ subscription, accessToken, onDoorbell, onError }) {
  const authClient = new OAuth2Client();
  authClient.setCredentials({ access_token: accessToken });
  // projectId comes from the subscription path the CORE handed us — never guessed from ADC, which is
  // what made the first staging probe fail with "Subscription does not exist".
  const pubsub = new PubSub({ projectId: subscription.split('/')[1], authClient });
  const sub = pubsub.subscription(subscription);
  sub.on('message', (m) => {
    onDoorbell(m.attributes);
    m.ack();
  });
  sub.on('error', (e) => onError(e?.message ?? e));
  return () => {
    sub.removeAllListeners();
    return sub.close().catch(() => {});
  };
}

async function main() {
  const outcome = await run({
    subscribe,
    sessionId: process.env['BATONDECK_SESSION_ID'],
    agentId: process.env['BATONDECK_AGENT_ID'],
    log: (m) => process.stderr.write(`[batondeck] ${m}\n`),
  });

  // An idle state is not a failure: say why, exit 0, and let the session carry on.
  if (typeof outcome === 'string') process.exit(0);

  process.stderr.write(`[batondeck] wake listener attached (${outcome.wpid}) -> ${outcome.file}\n`);
  for (const sig of ['SIGTERM', 'SIGINT']) {
    process.on(sig, () => {
      Promise.resolve(outcome.stop?.()).finally(() => process.exit(0));
    });
  }
}

// A listener that throws must not take the session's hook down with it.
main().catch((e) => {
  process.stderr.write(`[batondeck] wake listener failed: ${e?.message ?? e}\n`);
  process.exit(0);
});

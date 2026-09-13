#!/usr/bin/env node
/**
 * The MOUTH: block until this session's listener delivers something, then exit 0.
 *
 * The listener (the EAR) cannot wake an idle Claude Code session by itself — nothing can inject into a
 * live session. What the harness DOES wake on is a background task finishing, so the agent runs this as
 * one: it sleeps on the delivery file and exits the moment a doorbell lands, and the model is woken with
 * the event in the task's output.
 *
 * Dependency-free by design: it ships as plain node, never bundled.
 * Usage: node wake-wait.mjs [maxSeconds]   (default 3600)
 */
import { existsSync, statSync, openSync, readSync, closeSync, watch } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const maxSec = Number(process.argv[2] ?? 3600);
const sid = process.env['BATONDECK_SESSION_ID'] || 'default';
const file = join(homedir(), '.batondeck', 'wake', `${sid}.jsonl`);

/** Events worth waking for. A 'listening' line is bookkeeping; the rest all change what the agent should do. */
const WAKES = new Set(['doorbell', 'signin-required', 'unavailable', 'detached']);

function readFrom(offset) {
  if (!existsSync(file)) return { offset, lines: [] };
  const size = statSync(file).size;
  if (size <= offset) return { offset: size, lines: [] };
  const fd = openSync(file, 'r');
  const buf = Buffer.alloc(size - offset);
  readSync(fd, buf, 0, buf.length, offset);
  closeSync(fd);
  return { offset: size, lines: buf.toString('utf8').split('\n').filter(Boolean) };
}

// Start from the END: a doorbell that arrived before this wait was armed was already delivered to a
// previous turn, and replaying it would wake the agent for work it has done.
let offset = existsSync(file) ? statSync(file).size : 0;

const woke = (lines) => {
  const hits = lines.filter((l) => {
    try {
      return WAKES.has(JSON.parse(l).event);
    } catch {
      return false;
    }
  });
  if (hits.length === 0) return false;
  for (const h of hits) process.stdout.write(h + '\n');
  return true;
};

const done = (code) => process.exit(code);
const timer = setTimeout(() => {
  process.stdout.write(JSON.stringify({ event: 'wait-timeout', seconds: maxSec }) + '\n');
  done(0);
}, Math.max(1, maxSec) * 1000);

const check = () => {
  const r = readFrom(offset);
  offset = r.offset;
  if (woke(r.lines)) {
    clearTimeout(timer);
    done(0);
  }
};

// fs.watch where the platform supports it, plus a slow safety poll: a missed event must cost seconds,
// never the whole wait.
try {
  watch(join(homedir(), '.batondeck', 'wake'), { persistent: true }, check);
} catch {
  // no watcher available — the poll below carries it
}
setInterval(check, 2000);
check();

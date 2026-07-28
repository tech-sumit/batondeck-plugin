#!/usr/bin/env python3
"""batondeck-worker skill — the WAKE listener: block until this agent's doorbell rings.

T-70 part 3. The core has provisioned `wake-<workspace>-<wpid>` since T-70 part 1, filtered to
`attributes.agent = "<wpid>"`, and publishes an empty-bodied message to it on assignment. **Nothing
pulled it.** This does.

    BATONDECK_TOKEN --POST /mint--> wake --> {short-lived JWT, aud = this workspace's pool}
                                              |
                                    STS token exchange (workload identity federation)
                                              |
                                              v
                                    GCP access token --> pull wake-<workspace>-<wpid>

WHAT IT DOES ON A MESSAGE: exits 0 and says *nothing about the work*. The payload is contentless by
construction (spec §2.1 zero-authority payload: empty body, `agent` + `kind` attributes only), so the
only correct response is to go and re-read through the CORE, where authorization is enforced. This
prints `{"wake":{"kind":…,"count":N}}` and stops; the sweep is the caller's job and always was. No
board data ever travels this path.

IT RUNS ALONGSIDE `wait_for_updates`, NEVER INSTEAD OF IT. The long-poll is still the only
cross-instance fan-out and still carries cache invalidation; this is a second, cheaper ear. Start both
as background tasks and act on whichever returns first. If wake is off — the default posture
everywhere, `wake_enabled = false` — this exits 4 immediately with a reason and the worker behaves
exactly as it does today.

AUTH MODE, STATED (CONTRIBUTING rule 8): this needs `BATONDECK_TOKEN`, so it is available on exactly
the path `watch.sh` is — headless / bring-your-own-token — and NOT on the plugin's browser-OAuth path,
where the MCP token lives inside Claude Code's client and is invisible to Bash (T-62). On OAuth, loop
the `wait_for_updates` / `wait_for_task` MCP tools instead; there is no headless mint today.

    wake-listen.py [max_sec]        default 3500 (background-friendly)

EXIT CODES, matching watch.sh's conventions so both can be waited on the same way:
    0  the doorbell rang — re-read through the core (sweep your inbox), then wait again
    3  deadline, nothing rang — just re-run
    4  wake is NOT AVAILABLE here (no token, no wake service, no subscription, revoked). Do not
       retry in a loop; fall back to wait_for_updates alone. The reason is on stderr.
    1  something unexpected

Env:
    BATONDECK_TOKEN      REQUIRED — access token from https://mcp.batondeck.com. Nothing is minted.
    BATONDECK_WAKE_URL   the mint service (default https://wake.batondeck.com)
    BATONDECK_AGENT_ID   the agent SELECTOR sent as `x-batondeck-agent-id`; else read from
                         ${BATONDECK_STATE_DIR:-~/.batondeck}/agent-id (the same file agent-id.sh
                         and mcp.sh use, so all three are the same agent). Never generated here.
    BATONDECK_WAKE_PROJECT  Overrides the PROJECT SEGMENT of the subscription path. Default: whatever
                         the mint's `subscription` names (the project NUMBER), or — against a mint
                         older than T-95 — the number parsed out of the audience. Both forms were
                         MEASURED returning 200 on a pull (T-95, `projects/453775273608` and
                         `projects/batondeck-staging`), so this is an escape hatch, not a fix-up.
    BATONDECK_STATE_DIR  pidfile + agent-id location (default ~/.batondeck)
    BATONDECK_STS_URL / PUBSUB_EMULATOR_HOST   test hooks; see the integration suite.

── WHAT THIS CANNOT PROVE WITHOUT A LIVE DEPLOY. Read before quoting a green test run. ─────────────
`test/integration/wake-listener-pubsub.test.ts` drives this against the Pub/Sub EMULATOR with a
stubbed mint + STS whose `subscription` comes from the CORE's own `subscriptionResourceName`. That
proves the chain is walked and that the name this pulls is the one the core creates. It proves NOTHING
about GCP:
  * the STS exchange is stubbed. Whether Google accepts a `wake` JWT for direct resource access, and
    what `expires_in` it returns, is unmeasured.
  * the emulator has no IAM ("IAM integration is disabled"), so the per-subject binding T-82 writes is
    never tested — a pull that 403s live would be green here.
  * `projects/<NUMBER>` in the Pub/Sub resource path is untested HERE, but no longer unmeasured: T-95
    measured a live pull returning 200 for both the number and the id. BATONDECK_WAKE_PROJECT stays as
    the override; it is no longer the answer to an open question.
  * LONG-POLL: an empty `pull` was measured holding the full 30s against the emulator (fake v0.8.31,
    2026-07-28). Whether real Pub/Sub holds a synchronous Pull is NOT verified — Google steers callers
    to StreamingPull precisely because it may return an empty list promptly. If it does return early,
    this still works; only the cost claim changes, from ~0 idle requests to one per EMPTY_BACKOFF.
"""

from __future__ import annotations

import base64
import json
import os
import re
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

WAKE_URL_DEFAULT = "https://wake.batondeck.com"
STS_URL_DEFAULT = "https://sts.googleapis.com/v1/token"
PUBSUB_DEFAULT = "https://pubsub.googleapis.com"

PULL_TIMEOUT = 60  # per-pull HTTP budget; also the granularity at which we notice the deadline
EMPTY_BACKOFF = 5  # only ever slept when a pull returned EMPTY EARLY (i.e. the server did not hold it)
SUB_GRACE = 30  # provisioning is fire-and-forget off the MCP handshake, so a fresh session 404s first
REFRESH_SLACK = 120  # refresh this long before the GCP token expires
MINT_ATTEMPTS = 3  # a 429 (rate limit) or 5xx (cold start) is retried, never raised — see mint()
MINT_RETRY_SECS = 5

# FALLBACK ONLY, for a mint older than T-95. The audience `wake/src/lib.rs::audience_for` builds; the
# project number and the workspace are picked out of it so the subscription name can be rebuilt when the
# mint did not state one. A mint that DOES state it makes every line of this dead — which is the point:
# a name we reconstruct is a name we can get wrong, and getting it wrong is a silent 404.
AUDIENCE_RE = re.compile(
    r"^//iam\.googleapis\.com/projects/(\d+)/locations/global"
    r"/workloadIdentityPools/bd-wake-([a-z0-9-]+)/providers/wake-as$"
)


class Unavailable(Exception):
    """Exit 4 — wake cannot work here. Terminal, never retried."""


def log(msg: str) -> None:
    print(f"wake-listen: {msg}", file=sys.stderr, flush=True)


def post(url: str, body: bytes, headers: dict[str, str], timeout: float) -> tuple[int, bytes]:
    """One HTTP POST. Returns (status, body) for BOTH success and HTTP error.

    The error body is returned, never discarded: T-68 lost a run reporting failures with no reason
    because an STS error body went into a swallowed `$( )` (see scripts/wake-e2e.py's header).
    """
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def agent_id() -> str:
    """The SELECTOR the mint uses to pick which of this identity's agents to resolve. Never minted
    here — agent-id.sh owns creation, and inventing one would resolve a different (or no) session."""
    v = os.environ.get("BATONDECK_AGENT_ID", "").strip()
    if v:
        return v
    state = os.environ.get("BATONDECK_STATE_DIR") or os.path.join(os.path.expanduser("~"), ".batondeck")
    try:
        with open(os.path.join(state, "agent-id")) as f:
            return f.read().strip()
    except OSError:
        return ""


def jwt_claims(token: str) -> dict:
    """Read our OWN token's payload. No verification, deliberately: this is not a trust decision, it
    is reading back the `wpid` the server put there. GCP verifies it; we only need to name a resource."""
    part = token.split(".")[1]
    return json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))


class Credential:
    """A GCP access token plus the subscription it authorizes, and when it dies."""

    def __init__(self, access_token: str, expires_at: float, sub_path: str, slack: float):
        self.access_token = access_token
        self.expires_at = expires_at
        self.sub_path = sub_path
        self.slack = slack

    def stale(self, now: float) -> bool:
        return now >= self.expires_at - self.slack


def mint(token: str, wake_url: str) -> tuple[str, str, str | None]:
    """POST /mint -> (wake JWT, STS audience, subscription or None). The ONLY inputs are the bearer and
    the agent selector; `wpid` is resolved server-side from the session and never sent (wake/src/mint.rs).

    `subscription` is absent from a mint older than T-95, hence the `None`. Both shapes are handled in
    `acquire`, and only in that direction: a mint may lead its clients, never trail them.

    429 and 5xx are RETRIED, not raised. Both are foreseeable rather than exceptional: the mint
    rate-limits per credential (`MINTS_PER_WINDOW = 10` per 60s) and runs at `min_instances = 0`, so a
    cold start can 503. Letting either escape would kill the listener with a traceback and exit 1 —
    and note the asymmetry that would create, since a cold start slow enough to blow the 20s timeout is
    already caught below as `OSError` and degrades gracefully. Bounded, then Unavailable.
    """
    headers = {"authorization": f"Bearer {token}", "content-length": "0"}
    aid = agent_id()
    if aid:
        headers["x-batondeck-agent-id"] = aid
    last = ""
    for attempt in range(MINT_ATTEMPTS):
        try:
            status, raw = post(f"{wake_url.rstrip('/')}/mint", b"", headers, 20)
        except (urllib.error.URLError, OSError) as e:
            raise Unavailable(f"the wake service at {wake_url} is unreachable ({e}) — wake is off here") from e
        if status == 200:
            d = json.loads(raw)
            return d["token"], d["audience"], d.get("subscription")
        last = f"{status}: {raw.decode(errors='replace')[:300]}"
        # 401/403 are the mint refusing THIS caller (no session, disabled account, demo identity); 404
        # is no wake service deployed. All terminal — retrying cannot change the answer.
        if status in (401, 403, 404):
            raise Unavailable(f"mint refused ({last})")
        if attempt + 1 < MINT_ATTEMPTS:
            log(f"mint failed ({last}) — retrying in {MINT_RETRY_SECS}s")
            time.sleep(MINT_RETRY_SECS)
    raise Unavailable(f"mint failed {MINT_ATTEMPTS}x ({last})")


def exchange(wake_jwt: str, audience: str, sts_url: str) -> tuple[str, float]:
    """STS token exchange -> (GCP access token, lifetime seconds).

    DIRECT RESOURCE ACCESS, no service-account impersonation: the federated principal
    `principal://…/subject/<wpid>` is what `roles/pubsub.subscriber` is granted to (T-82), so the
    exchanged token is used against Pub/Sub as itself.
    """
    form = urllib.parse.urlencode({
        "audience": audience,
        "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
        "requested_token_type": "urn:ietf:params:oauth:token-type:access_token",
        "scope": "https://www.googleapis.com/auth/cloud-platform",
        "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
        "subject_token": wake_jwt,
    }).encode()
    status, raw = post(sts_url, form, {"content-type": "application/x-www-form-urlencoded"}, 20)
    if status != 200:
        # Verbatim. An STS refusal names which of issuer / audience / subject / attribute-condition
        # failed, and that sentence is the entire diagnosis.
        raise Unavailable(f"STS exchange refused ({status}): {raw.decode(errors='replace')[:500]}")
    d = json.loads(raw)
    # LIFETIME IS READ, NOT ASSUMED. The mint's ≤5min TTL bounds mint→exchange only; some federations
    # cap the exchanged token at the subject token's remaining life instead of the usual ~1h. Driving
    # off `expires_in` is correct under either, and it is why this refreshes ~hourly rather than every
    # 5 minutes — the wake JWT is used ONCE, immediately, and never held.
    return d["access_token"], float(d.get("expires_in", 3600))


def acquire(token: str, wake_url: str, sts_url: str) -> Credential:
    wake_jwt, audience, sub = mint(token, wake_url)
    claims = jwt_claims(wake_jwt)
    wpid = claims.get("wpid") or claims.get("sub") or ""
    if not re.fullmatch(r"[0-9a-f-]{36}", wpid):
        raise Unavailable(f"minted token carries no usable wpid ({wpid!r})")

    if sub is None:
        # LEGACY MINT (pre-T-95): rebuild `wake-<workspace>-<wpid>` — the name
        # src/wake/channel.ts::subscriptionName builds — from the audience and the token. Kept because
        # a client that requires the new field could not talk to a mint that predates it, and the
        # deploy order is not ours to choose. Delete this branch once no such mint is reachable.
        m = AUDIENCE_RE.match(audience)
        if not m:
            raise Unavailable(
                f"mint returned neither a subscription nor an audience this listener can parse: {audience!r}"
            )
        sub = f"projects/{m.group(1)}/subscriptions/wake-{m.group(2)}-{wpid}"
    elif wpid not in sub:
        # The one check worth making on a server-supplied path: it is THIS agent's doorbell. Anything
        # stricter would be another copy of the naming convention — the copy T-95 exists to delete —
        # and would mask a mint that legitimately moved the name rather than reveal a wrong one.
        raise Unavailable(f"the mint named a subscription that is not this agent's: {sub!r}")

    # The project segment is the one part still open to doubt (see the module docstring), so the escape
    # hatch rewrites it on BOTH shapes rather than only on the guess it used to override.
    project = os.environ.get("BATONDECK_WAKE_PROJECT")
    if project:
        sub = re.sub(r"^projects/[^/]+/", f"projects/{project}/", sub)

    started = time.monotonic()
    access, life = exchange(wake_jwt, audience, sts_url)
    slack = min(REFRESH_SLACK, life / 3)
    return Credential(access, started + life, sub, slack)


def pubsub_base() -> str:
    emu = os.environ.get("PUBSUB_EMULATOR_HOST")
    return f"http://{emu}" if emu else PUBSUB_DEFAULT


def pull(cred: Credential, budget: float) -> tuple[list[dict], float]:
    """One long-poll pull. Returns (messages, elapsed). A socket timeout IS the long poll expiring."""
    url = f"{pubsub_base()}/v1/{cred.sub_path}:pull"
    headers = {"authorization": f"Bearer {cred.access_token}", "content-type": "application/json"}
    started = time.monotonic()
    try:
        status, raw = post(url, json.dumps({"maxMessages": 16}).encode(), headers, budget)
    except (socket.timeout, TimeoutError):
        return [], time.monotonic() - started
    except (urllib.error.URLError, OSError) as e:
        # A closed port / DNS failure. Not terminal — Pub/Sub blips, and the loop's deadline bounds us.
        log(f"pull failed transiently: {e}")
        time.sleep(min(EMPTY_BACKOFF, budget))
        return [], time.monotonic() - started
    elapsed = time.monotonic() - started
    if status == 200:
        return json.loads(raw or b"{}").get("receivedMessages", []) or [], elapsed
    if status == 404:
        raise FileNotFoundError(raw.decode(errors="replace")[:300])
    if status in (401, 403):
        raise PermissionError(raw.decode(errors="replace")[:300])
    log(f"pull returned {status}: {raw.decode(errors='replace')[:200]}")
    time.sleep(min(EMPTY_BACKOFF, budget))
    return [], elapsed


def ack(cred: Credential, ack_ids: list[str]) -> None:
    """Best-effort: an un-acked doorbell is redelivered, which costs one spurious sweep, not
    correctness. Never worth failing the wake over."""
    if not ack_ids:
        return
    try:
        post(
            f"{pubsub_base()}/v1/{cred.sub_path}:acknowledge",
            json.dumps({"ackIds": ack_ids}).encode(),
            {"authorization": f"Bearer {cred.access_token}", "content-type": "application/json"},
            10,
        )
    except (urllib.error.URLError, OSError) as e:
        log(f"ack failed (harmless — the doorbell may ring twice): {e}")


def main(argv: list[str]) -> int:
    max_sec = float(argv[1]) if len(argv) > 1 else 3500.0
    token = os.environ.get("BATONDECK_TOKEN") or os.environ.get("CONDUCTOR_TOKEN") or ""
    if not token:
        log("no BATONDECK_TOKEN — the mint needs one and nothing mints it. On the plugin's browser-OAuth "
            "path the MCP token is invisible to Bash (T-62): loop the wait_for_updates / wait_for_task "
            "MCP tools instead. Wake is unavailable here; the worker is unaffected.")
        return 4
    wake_url = os.environ.get("BATONDECK_WAKE_URL", WAKE_URL_DEFAULT)
    sts_url = os.environ.get("BATONDECK_STS_URL", STS_URL_DEFAULT)

    # Same pidfile shape watch.sh writes, in the same dir: the plugin's Stop gate globs
    # `watch-<session>-*.pid` and lets the session idle while one is alive. A listener the gate cannot
    # see would be a background wait that still burns turns.
    state = os.environ.get("BATONDECK_STATE_DIR") or os.path.join(os.path.expanduser("~"), ".batondeck")
    pidf = os.path.join(state, f"watch-{os.environ.get('BATONDECK_SESSION_ID', 'default')}-{os.getpid()}.pid")
    try:
        os.makedirs(state, exist_ok=True)
        with open(pidf, "w") as f:
            f.write(str(os.getpid()))
    except OSError:
        pidf = ""

    try:
        return listen(token, wake_url, sts_url, max_sec)
    except Unavailable as e:
        log(f"{e}")
        log("wake is unavailable — fall back to wait_for_updates alone. Do not re-run this in a loop.")
        return 4
    finally:
        if pidf:
            try:
                os.remove(pidf)
            except OSError:
                pass


def listen(token: str, wake_url: str, sts_url: str, max_sec: float) -> int:
    deadline = time.monotonic() + max_sec
    cred: Credential | None = None
    refreshed_on_denial = False
    first_404: float | None = None

    while time.monotonic() < deadline:
        now = time.monotonic()
        if cred is None or cred.stale(now):
            cred = acquire(token, wake_url, sts_url)

        # THE ANSWER TO "what happens to an in-flight pull across a rotation": there is never one. The
        # budget is clamped to the credential's remaining life minus its slack, so a pull cannot
        # outlive the token it was issued under; rotation always happens between pulls, never during.
        budget = min(PULL_TIMEOUT, deadline - time.monotonic(), cred.expires_at - cred.slack - time.monotonic())
        if budget <= 1:
            time.sleep(1)  # a sub-second budget is the deadline or a rotation arriving; do not spin on it
            continue

        try:
            msgs, elapsed = pull(cred, budget)
        except FileNotFoundError as e:
            # The subscription is not there. Provisioning hangs off the MCP `initialize` handshake and
            # is fire-and-forget, so a session that just connected legitimately 404s for a moment —
            # wake-e2e.py loops 10×2s for exactly this. Only a PERSISTENT 404 means "wake is off".
            if first_404 is None:
                first_404 = time.monotonic()
            if time.monotonic() - first_404 < SUB_GRACE:
                time.sleep(2)
                continue
            raise Unavailable(
                f"no subscription at {cred.sub_path} after {SUB_GRACE}s: {e}. Either wake_enabled is "
                f"false in this deployment, or this agent has never completed an MCP handshake. If the "
                f"path looks right, try BATONDECK_WAKE_PROJECT=<project id>."
            ) from e
        except PermissionError as e:
            # One forced re-mint covers a token that died early. A second denial is revocation
            # (disconnect_agent is sticky) or a missing IAM binding — terminal either way.
            if refreshed_on_denial:
                raise Unavailable(f"pull denied on {cred.sub_path}: {e}") from e
            log("pull denied — re-minting once in case the credential died early")
            refreshed_on_denial, cred = True, None
            continue

        first_404 = None
        if msgs:
            ack(cred, [m["ackId"] for m in msgs if m.get("ackId")])
            # DELIBERATELY NOT filtered on `attributes.agent` here. The SUBSCRIPTION is the
            # authorization boundary and its server-side filter is what routes; a client-side re-check
            # would MASK a wrong name derivation rather than reveal it — and the name is the only new
            # thing this file computes. ponytail: no check, because the check would hide the bug.
            kinds = sorted({(m.get("message") or {}).get("attributes", {}).get("kind", "") for m in msgs})
            # Contentless by contract, and this print keeps it that way: a count and a kind, never a
            # payload. The caller re-reads through the core, where authorization is enforced.
            print(json.dumps({"wake": {"kind": kinds[0] if len(kinds) == 1 else kinds, "count": len(msgs)}}))
            return 0

        # Only sleeps when the server did NOT hold the request (see the long-poll caveat in the module
        # docstring). Against a broker that long-polls, this line never runs and idle costs 0 requests.
        if elapsed < budget / 2:
            time.sleep(min(EMPTY_BACKOFF, max(0.0, deadline - time.monotonic())))

    log(f"no wake before the {max_sec:.0f}s deadline (re-run to keep waiting)")
    return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv))

#!/usr/bin/env python3
"""batondeck-worker skill — plant a dependency-tree "tasknet" on a BatonDeck board from a JSON plan,
in ONE MCP session. Self-contained; works against any BatonDeck deployment.

Plan JSON (file arg or stdin):
{
  "projectId": "P-...",            # optional; falls back to $BATONDECK_PROJECT
  "boardId":   "B-...",            # optional; falls back to $BATONDECK_BOARD
  "sprint": { "name": "...", "goal": "...", "acceptance": "..." },   # OPTIONAL: propose a sprint
  "tasks": [
    { "key": "a", "title": "...", "description": "...",
      "priority": "high|normal|low|urgent", "labels": ["x"],
      "requiredCapabilities": ["typescript"], "customFields": {"k": "v"},
      "blockedBy": ["other-key", ...] }      # dependency edges, by key
  ]
}

With a "sprint" block the flow changes (spec: sprints design §5/§8): create_sprint runs FIRST
(-> PROPOSED), every member is created with its sprintId stamped and LEFT IN BACKLOG (the approval
latch — nothing is claimable until a human approves), and a proposal task is emitted, bound via
customFields.sprintProposalFor + update_sprint{proposalTaskId}, then completed with the full plan
as its deliverable -> REVIEW for the human. After human sign-off an admin activates the sprint and
promotes members BACKLOG -> READY. Without the block, behavior is exactly as before (all tasks
promoted to READY).

--dry-run prints every MCP call it WOULD make (no network, no token needed) — the self-test.

Connection (env): BATONDECK_CORE_URL (default hosted), BATONDECK_TOKEN (REQUIRED — an access token
issued by https://mcp.batondeck.com, audience = the core URL). Nothing is minted here: the gcloud ID
token this used to mint is rejected by the core on its issuer. Recommended auth is the BatonDeck
plugin's MCP OAuth (https://mcp.batondeck.com/mcp).

Usage:  scripts/seed-tasknet.py [--dry-run] plan.json   |   cat plan.json | scripts/seed-tasknet.py
"""
import json, os, sys, urllib.request

CORE = os.environ.get("BATONDECK_CORE_URL", "https://conductor-core-hn5syhhsja-el.a.run.app")

DRY = "--dry-run" in sys.argv
if DRY:
    sys.argv = [a for a in sys.argv if a != "--dry-run"]

# NO MINT HERE, DELIBERATELY: the core accepts only access tokens issued by the BatonDeck MCP
# authorization server (iss = https://mcp.batondeck.com, aud = core URL). The gcloud ID token this
# script used to mint carries iss = https://accounts.google.com and is rejected on the issuer —
# 401 UNAUTHENTICATED, every time. See src/auth/verify.ts.
TOKEN = os.environ.get("BATONDECK_TOKEN", "")
if not TOKEN and not DRY:
    sys.exit(
        "ERROR: no BATONDECK_TOKEN — and this seeder no longer mints one, because the token it used\n"
        "to mint is rejected by the core on its ISSUER. There is no headless token flow today (the\n"
        "authorization server offers only browser sign-in + refresh). Pick one:\n"
        "  * MCP OAuth (recommended): point your MCP client at https://mcp.batondeck.com/mcp — the\n"
        "    BatonDeck plugin ships this; other stdio clients: npx -y mcp-remote https://mcp.batondeck.com/mcp\n"
        "  * Bring your own: export BATONDECK_TOKEN=<access token from https://mcp.batondeck.com>\n"
        "  * Local dev core: AUTH_MODE=dev ignores the token — export BATONDECK_TOKEN=dev.\n"
        "`gcloud auth login` / `activate-service-account` cannot help: the rejection is on the issuer."
    )

_sid = None
_cookie = None
_n = 0

def _post(payload, expect_result):
    global _sid, _cookie
    headers = {"authorization": f"Bearer {TOKEN}", "content-type": "application/json",
               "accept": "application/json, text/event-stream"}
    if _sid: headers["mcp-session-id"] = _sid
    if _cookie: headers["cookie"] = _cookie
    req = urllib.request.Request(f"{CORE}/mcp", data=json.dumps(payload).encode(), headers=headers, method="POST")
    with urllib.request.urlopen(req) as r:
        if not _sid: _sid = r.headers.get("mcp-session-id")
        sc = r.headers.get("set-cookie")
        if sc and not _cookie: _cookie = sc.split(";", 1)[0]
        raw = r.read().decode()
    if not expect_result: return None
    for line in raw.splitlines():
        if line.startswith("data: "):
            d = json.loads(line[6:])
            if "error" in d: raise RuntimeError(d["error"])
            res = d["result"]
            if res.get("isError"): raise RuntimeError(res["content"][0]["text"])
            return res.get("structuredContent", res)
    raise RuntimeError("no data in SSE response")

def _dry_result(name):
    # Canned shapes for --dry-run, keyed by the fields main() actually reads back.
    if name == "create_sprint": return {"sprint": {"id": "S-dryrun000000", "version": 1}}
    if name == "create_task": return {"task": {"id": f"T-dry{_n}", "version": 1}}
    if name == "claim_task": return {"leaseId": "L-dryrun"}
    return {"task": {"version": 1}}

def call(name, args):
    global _n; _n += 1
    if DRY:
        print(f"  DRY {name} {json.dumps(args)}")
        return _dry_result(name)
    return _post({"jsonrpc": "2.0", "id": _n, "method": "tools/call",
                  "params": {"name": name, "arguments": args}}, True)

def main():
    raw = open(sys.argv[1]).read() if len(sys.argv) > 1 else sys.stdin.read()
    plan = json.loads(raw)
    project = plan.get("projectId") or os.environ["BATONDECK_PROJECT"]
    board = plan.get("boardId") or os.environ["BATONDECK_BOARD"]

    if not DRY:
        global _n; _n += 1
        _post({"jsonrpc": "2.0", "id": _n, "method": "initialize",
               "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                          "clientInfo": {"name": "seed-tasknet", "version": "1"}}}, True)
        _post({"jsonrpc": "2.0", "method": "notifications/initialized"}, False)

    # A "sprint" block flips the flow to propose-for-approval (sprints design §5/§8):
    # sprint FIRST, members stamped + left BACKLOG, proposal task -> REVIEW at the end.
    sprint = plan.get("sprint")
    sprint_doc = None
    if sprint:
        sprint_doc = call("create_sprint", {"projectId": project, "boardId": board,
                                            "name": sprint["name"], "goal": sprint["goal"],
                                            "acceptance": sprint["acceptance"]})["sprint"]
        print(f"Sprint {sprint_doc['id']} PROPOSED: {sprint['name']}")

    ids = {}
    for t in plan["tasks"]:
        args = {"projectId": project, "boardId": board, "title": t["title"]}
        if sprint_doc: args["sprintId"] = sprint_doc["id"]   # SINGULAR at create, by design
        for k in ("description", "priority", "labels", "requiredCapabilities", "customFields"):
            if t.get(k) is not None: args[k] = t[k]
        tid = call("create_task", args)["task"]["id"]
        ids[t["key"]] = tid
        print(f"  {tid:<6} {t.get('priority','normal'):<6} {t['title']}")

    edges = [(b, t["key"]) for t in plan["tasks"] for b in t.get("blockedBy", [])]
    print(f"\nCreated {len(ids)} tasks. Wiring {len(edges)} dependency edges...")
    for blocker, blocked in edges:
        call("add_dependency", {"projectId": project, "fromTaskId": ids[blocker],
                                "toTaskId": ids[blocked], "type": "blocks"})
        print(f"  {ids[blocker]} blocks {ids[blocked]}  ({blocker} -> {blocked})")

    if sprint_doc:
        # Members stay in BACKLOG on purpose: under a PROPOSED sprint, BACKLOG is the approval
        # latch — structurally unclaimable until a human signs off and an admin activates.
        # The proposal task is NOT a sprint member (it would pollute the member counts); the
        # sprintProposalFor custom field is what binds activation to THIS task's DONE.
        pt = call("create_task", {
            "projectId": project, "boardId": board,
            "title": f"Sprint plan: {sprint['name']}",
            "description": "Approve this sprint plan. The full plan is this task's deliverable. "
                           "Reaching DONE here is the human sign-off that lets an admin activate "
                           "the sprint (update_sprint status ACTIVE), after which the master "
                           "promotes the members BACKLOG -> READY.",
            "labels": ["sprint-proposal", "no-artifact"],
            "customFields": {"sprintProposalFor": sprint_doc["id"]},
        })["task"]
        call("update_sprint", {"projectId": project, "sprintId": sprint_doc["id"],
                               "version": sprint_doc["version"],
                               "patch": {"proposalTaskId": pt["id"]}})   # legal only while PROPOSED
        call("move_task", {"projectId": project, "taskId": pt["id"], "version": pt["version"],
                           "toStatus": "READY"})
        lease = call("claim_task", {"projectId": project, "taskId": pt["id"]})["leaseId"]
        call("complete_task", {"projectId": project, "taskId": pt["id"], "leaseId": lease,
                               "deliverable": json.dumps(plan, indent=2)[:20000]})
        print(f"\nProposal {pt['id']} -> REVIEW; {len(ids)} members left in BACKLOG awaiting approval.")
        print("Next: human approves (REVIEW -> DONE) -> admin activates the sprint -> promote members READY.")
        print(json.dumps({"ids": ids, "sprintId": sprint_doc["id"], "proposalTaskId": pt["id"]}))
        return

    # Promote EVERY task out of BACKLOG (create_task's first column) to READY — otherwise nothing is
    # claimable and nothing ever promotes it: auto-unblock only fires on BLOCKED tasks, so a BACKLOG task
    # whose blockers all complete would sit in BACKLOG forever. This is safe even for still-blocked tasks:
    # a READY task with a non-empty blockedBy is excluded from selection (next_task/claim_next only
    # consider blockedBy-empty READY tasks), and the moment auto-unblock empties blockedBy it becomes
    # eligible with NO further status change. add_dependency bumped versions, so re-read each first.
    print(f"\nPromoting {len(ids)} tasks BACKLOG -> READY...")
    for tid in ids.values():
        v = call("get_task", {"projectId": project, "taskId": tid})["task"]["version"]
        call("move_task", {"projectId": project, "taskId": tid, "version": v, "toStatus": "READY"})
        print(f"  {tid} -> READY")
    print(json.dumps({"ids": ids}))

if __name__ == "__main__":
    main()

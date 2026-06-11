#!/usr/bin/env python3
"""batondeck-worker skill — plant a dependency-tree "tasknet" on a Conductor board from a JSON plan,
in ONE MCP session. Self-contained; works against any Conductor deployment.

Plan JSON (file arg or stdin):
{
  "projectId": "P-...",            # optional; falls back to $CONDUCTOR_PROJECT
  "boardId":   "B-...",            # optional; falls back to $CONDUCTOR_BOARD
  "tasks": [
    { "key": "a", "title": "...", "description": "...",
      "priority": "high|normal|low|urgent", "labels": ["x"],
      "requiredCapabilities": ["typescript"], "customFields": {"k": "v"},
      "blockedBy": ["other-key", ...] }      # dependency edges, by key
  ]
}

Connection (env): CONDUCTOR_CORE_URL (default hosted), CONDUCTOR_TOKEN (bring your own) or
CONDUCTOR_AGENT_SA (mint by impersonating your agent SA), CONDUCTOR_ON_BEHALF_OF (gateway-SA only).

Usage:  scripts/seed-tasknet.py plan.json   |   cat plan.json | scripts/seed-tasknet.py
"""
import json, os, subprocess, sys, urllib.request

CORE = os.environ.get("CONDUCTOR_CORE_URL", "https://conductor-core-hn5syhhsja-el.a.run.app")
OBO = os.environ.get("CONDUCTOR_ON_BEHALF_OF")

def _mint():
    sa = os.environ.get("CONDUCTOR_AGENT_SA")
    cmd = ["gcloud", "auth", "print-identity-token", f"--audiences={CORE}"]
    if sa: cmd += [f"--impersonate-service-account={sa}", "--include-email"]
    return subprocess.check_output(cmd, stderr=subprocess.DEVNULL).decode().strip()

TOKEN = os.environ.get("CONDUCTOR_TOKEN") or _mint()

_sid = None
_cookie = None
_n = 0

def _post(payload, expect_result):
    global _sid, _cookie
    headers = {"authorization": f"Bearer {TOKEN}", "content-type": "application/json",
               "accept": "application/json, text/event-stream"}
    if OBO: headers["x-conductor-on-behalf-of"] = OBO
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

def call(name, args):
    global _n; _n += 1
    return _post({"jsonrpc": "2.0", "id": _n, "method": "tools/call",
                  "params": {"name": name, "arguments": args}}, True)

def main():
    raw = open(sys.argv[1]).read() if len(sys.argv) > 1 else sys.stdin.read()
    plan = json.loads(raw)
    project = plan.get("projectId") or os.environ["CONDUCTOR_PROJECT"]
    board = plan.get("boardId") or os.environ["CONDUCTOR_BOARD"]

    global _n; _n += 1
    _post({"jsonrpc": "2.0", "id": _n, "method": "initialize",
           "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                      "clientInfo": {"name": "seed-tasknet", "version": "1"}}}, True)
    _post({"jsonrpc": "2.0", "method": "notifications/initialized"}, False)

    ids = {}
    for t in plan["tasks"]:
        args = {"projectId": project, "boardId": board, "title": t["title"]}
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
    print(json.dumps({"ids": ids}))

if __name__ == "__main__":
    main()

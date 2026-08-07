#!/usr/bin/env python3
"""Validate plugins/batondeck against the Agent Plugins 1.0.0 specification.

Checks, in order:

  1. plugin.json  — against the vendored canonical schema, plus the semantic
     rules the schema cannot express (name shape, `./`-prefixed paths that stay
     inside the plugin root, reverse-domain extension namespaces).
  2. mcp.json     — against the vendored canonical schema, plus transport rules
     (HTTPS for non-loopback URLs, no credentials in headers/env, plugin-relative
     stdio commands).
  3. skills/      — non-recursive discovery, each skill's SKILL.md frontmatter
     against the Agent Skills specification.
  4. The client-specific manifests (.claude-plugin, .cursor-plugin) and the
     marketplace listings still agree with the portable manifest on name and
     version.

Schemas are vendored under .github/schemas/ deliberately: the spec says clients
select validation rules by `$schema` identifier and do not fetch schemas while
loading a plugin, so CI does not fetch them either.

Usage: validate-plugin.py [plugin-dir]
"""

from __future__ import annotations

import ipaddress
import json
import os
import re
import sys
from pathlib import Path
from urllib.parse import urlparse

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("PyYAML is required: pip install pyyaml")

try:
    from jsonschema import Draft202012Validator
except ImportError:  # pragma: no cover
    sys.exit("jsonschema is required: pip install jsonschema")

REPO = Path(__file__).resolve().parents[2]
SCHEMAS = REPO / ".github" / "schemas"

PLUGIN_SCHEMA_ID = "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json"
MCP_SCHEMA_ID = "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json"

# Agent Plugins 1.0.0 §plugin name
PLUGIN_NAME_RE = re.compile(r"^(?!.*(?:--|\.\.))[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$")
# Agent Skills: lowercase alphanumerics and hyphens, no leading/trailing/double hyphen
SKILL_NAME_RE = re.compile(r"^(?!.*--)[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$")
# Reverse-domain extension namespace, e.g. com.example.client
NAMESPACE_RE = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$")

SKILL_FRONTMATTER_KEYS = {"name", "description", "license", "compatibility", "metadata", "allowed-tools"}

SECRET_HINT_RE = re.compile(r"authorization|api[-_]?key|token|secret|password|bearer|cookie", re.I)

errors: list[str] = []
warnings: list[str] = []


def rel(path: Path) -> str:
    """Repo-relative path when possible, absolute otherwise (validator is reusable)."""
    try:
        return str(path.relative_to(REPO))
    except ValueError:
        return str(path)


def fail(msg: str) -> None:
    errors.append(msg)


def warn(msg: str) -> None:
    warnings.append(msg)


def load_json(path: Path):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        fail(f"{rel(path)}: missing")
    except json.JSONDecodeError as exc:
        fail(f"{rel(path)}: invalid JSON — {exc}")
    return None


def check_schema(doc, schema_path: Path, label: str) -> None:
    schema = json.loads(schema_path.read_text())
    for err in sorted(Draft202012Validator(schema).iter_errors(doc), key=lambda e: list(e.path)):
        where = "/".join(str(p) for p in err.path) or "(root)"
        fail(f"{label}: {where}: {err.message}")


def contained(root: Path, value: str, label: str) -> None:
    """A configured path MUST start with ./ and stay inside the plugin root."""
    if not value.startswith("./"):
        fail(f"{label}: configured path {value!r} must start with './'")
        return
    target = (root / value[2:]).resolve()
    if not str(target).startswith(str(root.resolve()) + os.sep):
        fail(f"{label}: {value!r} resolves outside the plugin root")
    elif not target.exists():
        fail(f"{label}: {value!r} does not exist")


def validate_manifest(root: Path) -> dict:
    path = root / "plugin.json"
    doc = load_json(path)
    if doc is None:
        return {}
    label = rel(path)
    check_schema(doc, SCHEMAS / "agent-plugins-1.0.0-plugin.schema.json", label)

    if doc.get("$schema") != PLUGIN_SCHEMA_ID:
        fail(f"{label}: $schema must be {PLUGIN_SCHEMA_ID}")

    name = doc.get("name", "")
    if not PLUGIN_NAME_RE.match(name) or not 1 <= len(name) <= 64:
        fail(f"{label}: name {name!r} violates the Agent Plugins name rules")

    for namespace, payload in (doc.get("extensions") or {}).items():
        if not NAMESPACE_RE.match(namespace):
            fail(f"{label}: extension namespace {namespace!r} is not reverse-domain")
        # Namespace contents are opaque to the spec, but our own path pointers
        # should still resolve — a dangling pointer is a packaging bug.
        for key, value in payload.items():
            if isinstance(value, str) and value.startswith("./"):
                contained(root, value, f"{label}: extensions.{namespace}.{key}")
    return doc


def validate_mcp(root: Path) -> None:
    path = root / "mcp.json"
    doc = load_json(path)
    if doc is None:
        return
    label = rel(path)
    check_schema(doc, SCHEMAS / "agent-plugins-1.0.0-mcp.schema.json", label)

    if doc.get("$schema") != MCP_SCHEMA_ID:
        fail(f"{label}: $schema must be {MCP_SCHEMA_ID}")

    for server, cfg in (doc.get("mcpServers") or {}).items():
        where = f"{label}: mcpServers.{server}"
        kind = cfg.get("type")
        if kind == "stdio":
            command = cfg.get("command", "")
            if command.startswith("./"):
                contained(root, command, f"{where}.command")
            elif "/" in command:
                fail(f"{where}.command: must be a bare executable name or a './'-prefixed path")
            for key in cfg.get("env", {}):
                if SECRET_HINT_RE.search(key):
                    fail(f"{where}.env: {key!r} looks like a credential; env is visible package data")
        elif kind in ("streamable-http", "sse"):
            url = urlparse(cfg.get("url", ""))
            if url.scheme not in ("http", "https"):
                fail(f"{where}.url: must be an absolute http/https URL")
            elif url.scheme == "http" and not is_loopback(url.hostname):
                fail(f"{where}.url: non-loopback URLs must use HTTPS")
            for header in cfg.get("headers", {}):
                if SECRET_HINT_RE.search(header):
                    fail(f"{where}.headers: {header!r} looks like a credential; headers are visible package data")
        else:
            fail(f"{where}.type: unknown transport {kind!r}")


def is_loopback(host: str | None) -> bool:
    if host in ("localhost", None):
        return host == "localhost"
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def validate_skills(root: Path) -> None:
    skills_dir = root / "skills"
    if not skills_dir.is_dir():
        return
    found = 0
    for child in sorted(skills_dir.iterdir()):
        if not child.is_dir():
            continue
        skill_md = child / "SKILL.md"
        if not skill_md.is_file():
            # Not a skill; the spec forbids recursing deeper to find one.
            warn(f"skills/{child.name}: no SKILL.md — not discovered as a skill")
            continue
        found += 1
        validate_skill(child, skill_md)
    if not found:
        warn("skills/: no skills discovered")


def validate_skill(directory: Path, skill_md: Path) -> None:
    label = rel(skill_md)
    text = skill_md.read_text()
    match = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not match:
        fail(f"{label}: missing YAML frontmatter")
        return
    try:
        fm = yaml.safe_load(match.group(1))
    except yaml.YAMLError as exc:
        fail(f"{label}: frontmatter is not valid YAML — {exc}")
        return
    if not isinstance(fm, dict):
        fail(f"{label}: frontmatter must be a mapping")
        return

    for key in set(fm) - SKILL_FRONTMATTER_KEYS:
        warn(f"{label}: unknown frontmatter key {key!r}")

    name = fm.get("name")
    if not isinstance(name, str) or not 1 <= len(name) <= 64 or not SKILL_NAME_RE.match(name):
        fail(f"{label}: name {name!r} violates the Agent Skills name rules")
    elif name != directory.name:
        fail(f"{label}: name {name!r} must match the parent directory {directory.name!r}")

    description = fm.get("description")
    if not isinstance(description, str) or not description.strip():
        fail(f"{label}: description is required and must be non-empty")
    elif len(description) > 1024:
        fail(f"{label}: description is {len(description)} characters (max 1024)")

    compatibility = fm.get("compatibility")
    if compatibility is not None and len(str(compatibility)) > 500:
        fail(f"{label}: compatibility is {len(str(compatibility))} characters (max 500)")

    metadata = fm.get("metadata")
    if metadata is not None and (
        not isinstance(metadata, dict)
        or any(not isinstance(k, str) or not isinstance(v, str) for k, v in metadata.items())
    ):
        fail(f"{label}: metadata must be a map of string keys to string values")


def validate_client_manifests(root: Path, portable: dict) -> None:
    """Portable and client manifests ship in one package; they must not drift."""
    for relative in (".claude-plugin/plugin.json", ".cursor-plugin/plugin.json"):
        path = root / relative
        if not path.exists():
            continue
        doc = load_json(path)
        if doc is None:
            continue
        for field in ("name", "version"):
            if doc.get(field) != portable.get(field):
                fail(
                    f"{rel(path)}: {field} is {doc.get(field)!r} but "
                    f"plugin.json says {portable.get(field)!r}"
                )


def validate_marketplaces(portable: dict) -> None:
    """Marketplace listings advertise a version; keep it in step with the manifest."""
    for relative in (".claude-plugin/marketplace.json", ".cursor-plugin/marketplace.json"):
        path = REPO / relative
        if not path.exists():
            continue
        doc = load_json(path)
        if doc is None:
            continue
        for entry in doc.get("plugins", []):
            if entry.get("name") != portable.get("name"):
                continue
            if entry.get("version") != portable.get("version"):
                fail(
                    f"{rel(path)}: {entry['name']} is listed at {entry.get('version')!r} but "
                    f"plugin.json says {portable.get('version')!r}"
                )


def main() -> int:
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else REPO / "plugins" / "batondeck"
    if not root.is_dir():
        sys.exit(f"{root}: not a directory")

    portable = validate_manifest(root)
    validate_mcp(root)
    validate_skills(root)
    if portable:
        validate_client_manifests(root, portable)
        if root == REPO / "plugins" / "batondeck":
            validate_marketplaces(portable)

    for message in warnings:
        print(f"warning: {message}")
    for message in errors:
        print(f"error: {message}")

    if errors:
        print(f"\n{root.name}: {len(errors)} error(s) against Agent Plugins 1.0.0")
        return 1
    print(f"{root.name}: conforms to Agent Plugins 1.0.0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

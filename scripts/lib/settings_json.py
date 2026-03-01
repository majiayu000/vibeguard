#!/usr/bin/env python3
"""Helpers for reading/updating ~/.claude/settings.json for VibeGuard setup."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def load_settings(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError("settings.json root must be an object")
    return data


def save_settings(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


def _entry_contains(entry: Any, needle: str) -> bool:
    try:
        return needle in json.dumps(entry, ensure_ascii=False)
    except (TypeError, ValueError):
        return False


def has_mcp(data: dict[str, Any]) -> bool:
    servers = data.get("mcpServers", {})
    return isinstance(servers, dict) and "vibeguard" in servers


def has_pre_hooks(data: dict[str, Any]) -> bool:
    hooks = data.get("hooks", {})
    pre = hooks.get("PreToolUse", []) if isinstance(hooks, dict) else []
    return (
        any(_entry_contains(entry, "pre-write-guard") for entry in pre)
        and any(_entry_contains(entry, "pre-bash-guard") for entry in pre)
        and any(_entry_contains(entry, "pre-edit-guard") for entry in pre)
        and any(_entry_contains(entry, "skills-loader") for entry in pre)
    )


def has_post_hooks(data: dict[str, Any]) -> bool:
    hooks = data.get("hooks", {})
    post = hooks.get("PostToolUse", []) if isinstance(hooks, dict) else []
    return (
        any(_entry_contains(entry, "post-guard-check") for entry in post)
        and any(_entry_contains(entry, "post-edit-guard") for entry in post)
        and any(_entry_contains(entry, "post-write-guard") for entry in post)
    )


def has_full_hooks(data: dict[str, Any]) -> bool:
    hooks = data.get("hooks", {})
    post = hooks.get("PostToolUse", []) if isinstance(hooks, dict) else []
    stop = hooks.get("Stop", []) if isinstance(hooks, dict) else []
    return (
        has_post_hooks(data)
        and any(_entry_contains(entry, "post-build-check") for entry in post)
        and any(_entry_contains(entry, "stop-guard") for entry in stop)
        and any(_entry_contains(entry, "learn-evaluator") for entry in stop)
    )


def upsert_hook(hooks: dict[str, Any], repo_dir: str, event: str, matcher: str, script_name: str, state: dict[str, bool]) -> None:
    entries = hooks.setdefault(event, [])
    if not isinstance(entries, list):
        entries = []
        hooks[event] = entries
        state["changed"] = True

    desired_command = f"bash {repo_dir}/hooks/{script_name}"
    found = False

    for entry in entries:
        if not isinstance(entry, dict):
            continue
        if matcher:
            if entry.get("matcher") != matcher:
                continue
        else:
            hook_entries = entry.get("hooks", [])
            if not any(
                isinstance(h, dict) and script_name in str(h.get("command", ""))
                for h in hook_entries
            ):
                continue

        hook_entries = entry.get("hooks")
        if not isinstance(hook_entries, list):
            entry["hooks"] = [{"type": "command", "command": desired_command}]
            state["changed"] = True
            found = True
            continue

        for hook in hook_entries:
            if not isinstance(hook, dict):
                continue
            cmd = hook.get("command", "")
            if script_name not in str(cmd):
                continue
            found = True
            if hook.get("type") != "command" or cmd != desired_command:
                hook["type"] = "command"
                hook["command"] = desired_command
                state["changed"] = True

    if not found:
        new_entry: dict[str, Any] = {
            "hooks": [{"type": "command", "command": desired_command}]
        }
        if matcher:
            new_entry["matcher"] = matcher
        entries.append(new_entry)
        state["changed"] = True


def cmd_check(args: argparse.Namespace) -> int:
    data = load_settings(Path(args.settings_file))
    if args.target == "mcp":
        return 0 if has_mcp(data) else 1
    if args.target == "pre-hooks":
        return 0 if has_pre_hooks(data) else 1
    if args.target == "post-hooks":
        return 0 if has_post_hooks(data) else 1
    if args.target == "full-hooks":
        return 0 if has_full_hooks(data) else 1
    return 1


def cmd_upsert_vibeguard(args: argparse.Namespace) -> int:
    settings_path = Path(args.settings_file)
    data = load_settings(settings_path)
    state = {"changed": False}

    desired_server = {
        "type": "stdio",
        "command": "node",
        "args": [f"{args.repo_dir}/mcp-server/dist/index.js"],
    }
    mcp_servers = data.setdefault("mcpServers", {})
    if not isinstance(mcp_servers, dict):
        mcp_servers = {}
        data["mcpServers"] = mcp_servers
        state["changed"] = True
    if mcp_servers.get("vibeguard") != desired_server:
        mcp_servers["vibeguard"] = desired_server
        state["changed"] = True

    hooks = data.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        hooks = {}
        data["hooks"] = hooks
        state["changed"] = True

    upsert_hook(hooks, args.repo_dir, "PreToolUse", "Write", "pre-write-guard.sh", state)
    upsert_hook(hooks, args.repo_dir, "PreToolUse", "Bash", "pre-bash-guard.sh", state)
    upsert_hook(hooks, args.repo_dir, "PreToolUse", "Edit", "pre-edit-guard.sh", state)
    upsert_hook(hooks, args.repo_dir, "PreToolUse", "Read", "skills-loader.sh", state)
    upsert_hook(hooks, args.repo_dir, "PostToolUse", "mcp__vibeguard__guard_check", "post-guard-check.sh", state)
    upsert_hook(hooks, args.repo_dir, "PostToolUse", "Edit", "post-edit-guard.sh", state)
    upsert_hook(hooks, args.repo_dir, "PostToolUse", "Write", "post-write-guard.sh", state)
    if args.profile == "full":
        upsert_hook(hooks, args.repo_dir, "PostToolUse", "Edit", "post-build-check.sh", state)
        upsert_hook(hooks, args.repo_dir, "PostToolUse", "Write", "post-build-check.sh", state)
        upsert_hook(hooks, args.repo_dir, "Stop", "", "stop-guard.sh", state)
        upsert_hook(hooks, args.repo_dir, "Stop", "", "learn-evaluator.sh", state)

    if state["changed"]:
        save_settings(settings_path, data)
        print("CHANGED")
    else:
        print("SKIP")
    return 0


def cmd_remove_vibeguard(args: argparse.Namespace) -> int:
    settings_path = Path(args.settings_file)
    if not settings_path.exists():
        print("SKIP")
        return 0

    data = load_settings(settings_path)
    changed = False

    mcp_servers = data.get("mcpServers")
    if isinstance(mcp_servers, dict) and "vibeguard" in mcp_servers:
        del mcp_servers["vibeguard"]
        if not mcp_servers:
            data.pop("mcpServers", None)
        changed = True

    hooks = data.get("hooks")
    if isinstance(hooks, dict):
        if "PreToolUse" in hooks and isinstance(hooks["PreToolUse"], list):
            original = hooks["PreToolUse"]
            filtered = [
                h for h in original
                if not any(
                    _entry_contains(h, key)
                    for key in ("pre-write-guard", "pre-bash-guard", "pre-edit-guard", "skills-loader")
                )
            ]
            if len(filtered) != len(original):
                if filtered:
                    hooks["PreToolUse"] = filtered
                else:
                    hooks.pop("PreToolUse", None)
                changed = True

        if "PostToolUse" in hooks and isinstance(hooks["PostToolUse"], list):
            original = hooks["PostToolUse"]
            filtered = [
                h for h in original
                if not any(
                    _entry_contains(h, key)
                    for key in ("post-guard-check", "post-edit-guard", "post-write-guard", "post-build-check")
                )
            ]
            if len(filtered) != len(original):
                if filtered:
                    hooks["PostToolUse"] = filtered
                else:
                    hooks.pop("PostToolUse", None)
                changed = True

        if "Stop" in hooks and isinstance(hooks["Stop"], list):
            original = hooks["Stop"]
            filtered = [
                h for h in original
                if not any(_entry_contains(h, key) for key in ("stop-guard", "learn-evaluator"))
            ]
            if len(filtered) != len(original):
                if filtered:
                    hooks["Stop"] = filtered
                else:
                    hooks.pop("Stop", None)
                changed = True

        if not hooks:
            data.pop("hooks", None)
            changed = True

    if changed:
        save_settings(settings_path, data)
        print("CHANGED")
    else:
        print("SKIP")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="VibeGuard settings.json helper")
    sub = parser.add_subparsers(dest="command", required=True)

    check = sub.add_parser("check", help="Check installed state")
    check.add_argument("--settings-file", required=True)
    check.add_argument("--target", choices=["mcp", "pre-hooks", "post-hooks", "full-hooks"], required=True)
    check.set_defaults(func=cmd_check)

    upsert = sub.add_parser("upsert-vibeguard", help="Upsert VibeGuard MCP/hooks config")
    upsert.add_argument("--settings-file", required=True)
    upsert.add_argument("--repo-dir", required=True)
    upsert.add_argument("--profile", choices=["core", "full"], default="core")
    upsert.set_defaults(func=cmd_upsert_vibeguard)

    remove = sub.add_parser("remove-vibeguard", help="Remove VibeGuard MCP/hooks config")
    remove.add_argument("--settings-file", required=True)
    remove.set_defaults(func=cmd_remove_vibeguard)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())

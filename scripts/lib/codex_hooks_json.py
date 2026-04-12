#!/usr/bin/env python3
"""Helpers for reading/updating ~/.codex/hooks.json for VibeGuard setup."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


class HookSpec(dict):
    pass


MANAGED_SPECS: list[HookSpec] = [
    {
        "event": "PreToolUse",
        "matcher": "Bash",
        "script": "vibeguard-pre-bash-guard.sh",
        "timeout": 10,
    },
    {
        "event": "PostToolUse",
        "matcher": "Bash",
        "script": "vibeguard-post-build-check.sh",
        "timeout": 30,
    },
    {
        "event": "Stop",
        "matcher": None,
        "script": "vibeguard-stop-guard.sh",
        "timeout": None,
    },
    {
        "event": "Stop",
        "matcher": None,
        "script": "vibeguard-learn-evaluator.sh",
        "timeout": None,
    },
]

LEGACY_MARKERS = {
    "pre-bash-guard.sh",
    "post-build-check.sh",
    "stop-guard.sh",
    "learn-evaluator.sh",
    "post-guard-check.sh",
    "session-tagger.sh",
    "cognitive-reminder.sh",
}

MANAGED_MARKERS = LEGACY_MARKERS | {spec["script"] for spec in MANAGED_SPECS}


def load_hooks(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError("hooks.json root must be an object")
    return data


def save_hooks(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


def _ensure_hooks_root(data: dict[str, Any]) -> dict[str, Any]:
    hooks = data.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        hooks = {}
        data["hooks"] = hooks
    return hooks


def _is_vibeguard_command(command: str) -> bool:
    if not isinstance(command, str):
        return False
    if any(marker in command for marker in ("session-tagger.sh", "cognitive-reminder.sh", "post-guard-check.sh")):
        return True
    if "run-hook-codex.sh" not in command:
        return False
    return any(marker in command for marker in MANAGED_MARKERS)


def _prune_vibeguard_entries(data: dict[str, Any]) -> bool:
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        return False

    changed = False
    for event, entries in list(hooks.items()):
        if not isinstance(entries, list):
            continue

        new_entries: list[Any] = []
        for entry in entries:
            if not isinstance(entry, dict):
                new_entries.append(entry)
                continue

            hook_entries = entry.get("hooks")
            if not isinstance(hook_entries, list):
                new_entries.append(entry)
                continue

            kept_hooks = []
            removed_any = False
            for hook in hook_entries:
                if not isinstance(hook, dict):
                    kept_hooks.append(hook)
                    continue
                command = str(hook.get("command", ""))
                if _is_vibeguard_command(command):
                    removed_any = True
                    changed = True
                    continue
                kept_hooks.append(hook)

            if removed_any:
                if kept_hooks:
                    next_entry = dict(entry)
                    next_entry["hooks"] = kept_hooks
                    new_entries.append(next_entry)
                else:
                    # Remove empty hook entry shell.
                    changed = True
            else:
                new_entries.append(entry)

        if new_entries:
            hooks[event] = new_entries
        else:
            hooks.pop(event, None)
            changed = True

    if not hooks:
        data.pop("hooks", None)
        changed = True

    return changed


def _build_entry(wrapper: str, spec: HookSpec) -> dict[str, Any]:
    hook: dict[str, Any] = {
        "type": "command",
        "command": f"bash {wrapper} {spec['script']}",
    }
    timeout = spec.get("timeout")
    if isinstance(timeout, int):
        hook["timeout"] = timeout

    entry: dict[str, Any] = {"hooks": [hook]}
    matcher = spec.get("matcher")
    if isinstance(matcher, str) and matcher:
        entry["matcher"] = matcher
    return entry


def _has_entry(entries: list[Any], expected_command: str, expected_matcher: str | None) -> bool:
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        if expected_matcher is not None and entry.get("matcher") != expected_matcher:
            continue
        hook_entries = entry.get("hooks")
        if not isinstance(hook_entries, list):
            continue
        for hook in hook_entries:
            if not isinstance(hook, dict):
                continue
            if hook.get("command") == expected_command:
                return True
    return False


def cmd_upsert_vibeguard(args: argparse.Namespace) -> int:
    hooks_path = Path(args.hooks_file)
    data = load_hooks(hooks_path)
    before = json.dumps(data, sort_keys=True, ensure_ascii=False)

    _ensure_hooks_root(data)
    _prune_vibeguard_entries(data)
    hooks = _ensure_hooks_root(data)

    for spec in MANAGED_SPECS:
        event = str(spec["event"])
        entries = hooks.setdefault(event, [])
        if not isinstance(entries, list):
            entries = []
            hooks[event] = entries
        expected_command = f"bash {args.wrapper} {spec['script']}"
        expected_matcher = spec.get("matcher")
        if not _has_entry(entries, expected_command, expected_matcher if isinstance(expected_matcher, str) else None):
            entries.append(_build_entry(args.wrapper, spec))

    after = json.dumps(data, sort_keys=True, ensure_ascii=False)
    if after != before:
        save_hooks(hooks_path, data)
        print("CHANGED")
    else:
        print("SKIP")
    return 0


def cmd_remove_vibeguard(args: argparse.Namespace) -> int:
    hooks_path = Path(args.hooks_file)
    if not hooks_path.exists():
        print("SKIP")
        return 0

    data = load_hooks(hooks_path)
    before = json.dumps(data, sort_keys=True, ensure_ascii=False)
    _prune_vibeguard_entries(data)
    after = json.dumps(data, sort_keys=True, ensure_ascii=False)

    if before == after:
        print("SKIP")
        return 0

    if data:
        save_hooks(hooks_path, data)
    else:
        hooks_path.unlink(missing_ok=True)
    print("CHANGED")
    return 0


def cmd_check_vibeguard(args: argparse.Namespace) -> int:
    hooks_path = Path(args.hooks_file)
    data = load_hooks(hooks_path)
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        return 1

    for spec in MANAGED_SPECS:
        event = str(spec["event"])
        entries = hooks.get(event)
        if not isinstance(entries, list):
            return 1

        expected_command = f"bash {args.wrapper} {spec['script']}"
        expected_matcher = spec.get("matcher")
        if not _has_entry(entries, expected_command, expected_matcher if isinstance(expected_matcher, str) else None):
            return 1
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="VibeGuard ~/.codex/hooks.json helper")
    sub = parser.add_subparsers(dest="command", required=True)

    upsert = sub.add_parser("upsert-vibeguard", help="Upsert VibeGuard hook entries")
    upsert.add_argument("--hooks-file", required=True)
    upsert.add_argument("--wrapper", required=True)
    upsert.set_defaults(func=cmd_upsert_vibeguard)

    remove = sub.add_parser("remove-vibeguard", help="Remove VibeGuard hook entries")
    remove.add_argument("--hooks-file", required=True)
    remove.set_defaults(func=cmd_remove_vibeguard)

    check = sub.add_parser("check-vibeguard", help="Check VibeGuard hook entries")
    check.add_argument("--hooks-file", required=True)
    check.add_argument("--wrapper", required=True)
    check.set_defaults(func=cmd_check_vibeguard)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())

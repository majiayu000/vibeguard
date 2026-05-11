#!/usr/bin/env python3
"""Helpers for reading/updating ~/.claude/settings.json for VibeGuard setup."""

from __future__ import annotations

import argparse
import difflib
import json
import shlex
import sys
from pathlib import Path
from typing import Any

from hooks_manifest import all_managed_script_names, claude_specs, load_manifest


MANIFEST = load_manifest()


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


def render_settings(data: dict[str, Any]) -> str:
    return json.dumps(data, indent=2, ensure_ascii=False) + "\n"


def unified_diff(path: Path, before: str, after: str) -> str:
    return "".join(
        difflib.unified_diff(
            before.splitlines(keepends=True),
            after.splitlines(keepends=True),
            fromfile=str(path),
            tofile=str(path),
        )
    )


def _entry_contains(entry: Any, needle: str) -> bool:
    try:
        return needle in json.dumps(entry, ensure_ascii=False)
    except (TypeError, ValueError):
        return False


def _has_hook_spec(data: dict[str, Any], spec: dict[str, Any]) -> bool:
    hooks = data.get("hooks", {})
    entries = hooks.get(spec["event"], []) if isinstance(hooks, dict) else []
    if not isinstance(entries, list):
        return False
    expected_matcher = spec.get("matcher") or ""
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        if expected_matcher:
            if entry.get("matcher") != expected_matcher:
                continue
        elif "matcher" in entry and entry.get("matcher") not in ("", None):
            continue
        hook_entries = entry.get("hooks")
        if not isinstance(hook_entries, list):
            continue
        for hook in hook_entries:
            if isinstance(hook, dict) and spec["script"] in str(hook.get("command", "")):
                return True
    return False


def _has_all_specs(data: dict[str, Any], specs: list[dict[str, Any]]) -> bool:
    return all(_has_hook_spec(data, spec) for spec in specs)


def has_pre_hooks(data: dict[str, Any]) -> bool:
    specs = [spec for spec in claude_specs(MANIFEST, "minimal") if spec["event"] == "PreToolUse"]
    return _has_all_specs(data, specs)


def has_post_hooks(data: dict[str, Any]) -> bool:
    specs = [spec for spec in claude_specs(MANIFEST, "minimal") if spec["event"] == "PostToolUse"]
    return _has_all_specs(data, specs)


def has_full_hooks(data: dict[str, Any]) -> bool:
    core_scripts = {spec["script"] for spec in claude_specs(MANIFEST, "core")}
    specs = [
        spec
        for spec in claude_specs(MANIFEST, "full")
        if spec["script"] not in core_scripts
    ]
    return has_post_hooks(data) and _has_all_specs(data, specs)


def _hook_command(repo_dir: str, script_name: str) -> str:
    """Generate the hook command using the run-hook.sh wrapper."""
    home = Path.home()
    return f"bash {home}/.vibeguard/run-hook.sh {script_name}"


def _is_canonical_hook_command(command: str, script_name: str) -> bool:
    try:
        parts = shlex.split(command)
    except ValueError:
        return False
    return (
        len(parts) == 3
        and parts[0] == "bash"
        and parts[1].endswith("/.vibeguard/run-hook.sh")
        and parts[2] == script_name
    )


def _record_customized_command(state: dict[str, Any], script_name: str, command: str) -> None:
    customized = state.setdefault("customized", [])
    if isinstance(customized, list):
        customized.append({"script": script_name, "command": command})
    print(
        f"WARN: preserving customized VibeGuard hook command for {script_name}; "
        "use --force-overwrite to replace it",
        file=sys.stderr,
    )


def _remove_legacy_mcp_server(data: dict[str, Any]) -> bool:
    mcp_servers = data.get("mcpServers")
    if not isinstance(mcp_servers, dict) or "vibeguard" not in mcp_servers:
        return False

    del mcp_servers["vibeguard"]
    if not mcp_servers:
        data.pop("mcpServers", None)
    return True


def _remove_legacy_hook_entries(data: dict[str, Any]) -> bool:
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        return False

    changed = False
    legacy_keys = ("post-guard-check", "session-tagger", "cognitive-reminder")

    for event in ("PreToolUse", "PostToolUse", "Stop", "SessionStart"):
        entries = hooks.get(event)
        if not isinstance(entries, list):
            continue

        filtered = [
            entry for entry in entries
            if not any(_entry_contains(entry, key) for key in legacy_keys)
        ]
        if len(filtered) == len(entries):
            continue

        changed = True
        if filtered:
            hooks[event] = filtered
        else:
            hooks.pop(event, None)

    if not hooks:
        data.pop("hooks", None)

    return changed


def remove_hook(hooks: dict[str, Any], event: str, script_name: str, state: dict[str, bool]) -> None:
    """Remove a hook entry matching script_name from the given event."""
    entries = hooks.get(event)
    if not isinstance(entries, list):
        return
    filtered = [e for e in entries if not _entry_contains(e, script_name)]
    if len(filtered) != len(entries):
        if filtered:
            hooks[event] = filtered
        else:
            hooks.pop(event, None)
        state["changed"] = True


def upsert_hook(
    hooks: dict[str, Any],
    repo_dir: str,
    event: str,
    matcher: str,
    script_name: str,
    state: dict[str, Any],
    *,
    force_overwrite: bool = False,
) -> None:
    entries = hooks.setdefault(event, [])
    if not isinstance(entries, list):
        entries = []
        hooks[event] = entries
        state["changed"] = True

    desired_command = _hook_command(repo_dir, script_name)
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
            if hook.get("type") != "command":
                hook["type"] = "command"
                state["changed"] = True
            if cmd != desired_command:
                if force_overwrite or _is_canonical_hook_command(str(cmd), script_name):
                    hook["command"] = desired_command
                    state["changed"] = True
                else:
                    _record_customized_command(state, script_name, str(cmd))

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
    if args.target == "pre-hooks":
        return 0 if has_pre_hooks(data) else 1
    if args.target == "post-hooks":
        return 0 if has_post_hooks(data) else 1
    if args.target == "full-hooks":
        return 0 if has_full_hooks(data) else 1
    return 1


def cmd_upsert_vibeguard(args: argparse.Namespace) -> int:
    settings_path = Path(args.settings_file)
    before_text = settings_path.read_text(encoding="utf-8") if settings_path.exists() else ""
    data = load_settings(settings_path)
    state: dict[str, Any] = {"changed": False}

    if _remove_legacy_mcp_server(data):
        state["changed"] = True
    if _remove_legacy_hook_entries(data):
        state["changed"] = True

    hooks = data.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        hooks = {}
        data["hooks"] = hooks
        state["changed"] = True

    desired_specs = claude_specs(MANIFEST, args.profile)
    for spec in desired_specs:
        upsert_hook(
            hooks,
            args.repo_dir,
            spec["event"],
            spec["matcher"],
            spec["script"],
            state,
            force_overwrite=args.force_overwrite,
        )

    # Remove hooks that do not belong to the current profile (handles profile downgrade).
    desired_pairs = {(spec["event"], spec["script"]) for spec in desired_specs}
    for spec in claude_specs(MANIFEST):
        pair = (spec["event"], spec["script"])
        if pair not in desired_pairs:
            remove_hook(hooks, spec["event"], spec["script"], state)

    if args.dry_run:
        if state["changed"]:
            after_text = render_settings(data)
            print(unified_diff(settings_path, before_text, after_text), end="")
            print("CHANGED")
        else:
            print("SKIP")
        return 0

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

    if _remove_legacy_mcp_server(data):
        changed = True
    if _remove_legacy_hook_entries(data):
        changed = True

    hooks = data.get("hooks")
    if isinstance(hooks, dict):
        if "PreToolUse" in hooks and isinstance(hooks["PreToolUse"], list):
            original = hooks["PreToolUse"]
            filtered = [
                h for h in original
                if not any(
                    _entry_contains(h, key)
                    for key in all_managed_script_names(MANIFEST)
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
                    for key in all_managed_script_names(MANIFEST) | {"post-guard-check.sh"}
                )
            ]
            if len(filtered) != len(original):
                if filtered:
                    hooks["PostToolUse"] = filtered
                else:
                    hooks.pop("PostToolUse", None)
                changed = True

        for event in ("Stop", "SessionStart", "PreCompact", "UserPromptSubmit"):
            if event not in hooks or not isinstance(hooks[event], list):
                continue
            original = hooks[event]
            filtered = [
                h for h in original
                if not any(_entry_contains(h, key) for key in all_managed_script_names(MANIFEST))
            ]
            if len(filtered) != len(original):
                if filtered:
                    hooks[event] = filtered
                else:
                    hooks.pop(event, None)
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
    check.add_argument("--target", choices=["pre-hooks", "post-hooks", "full-hooks"], required=True)
    check.set_defaults(func=cmd_check)

    upsert = sub.add_parser("upsert-vibeguard", help="Upsert VibeGuard hooks config")
    upsert.add_argument("--settings-file", required=True)
    upsert.add_argument("--repo-dir", required=True)
    upsert.add_argument("--profile", choices=["minimal", "core", "full", "strict"], default="core")
    upsert.add_argument("--dry-run", action="store_true", help="Print unified diff without writing")
    upsert.add_argument("--force-overwrite", action="store_true", help="Replace customized managed hook commands")
    upsert.set_defaults(func=cmd_upsert_vibeguard)

    remove = sub.add_parser("remove-vibeguard", help="Remove VibeGuard hooks config and legacy MCP entries")
    remove.add_argument("--settings-file", required=True)
    remove.set_defaults(func=cmd_remove_vibeguard)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())

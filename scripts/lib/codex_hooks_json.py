#!/usr/bin/env python3
"""Helpers for reading/updating ~/.codex/hooks.json for VibeGuard setup."""

from __future__ import annotations

import argparse
import json
import shlex
from pathlib import Path
from typing import Any

from file_ops import write_json_atomic
from hook_config_model import hook_command_identity
from hooks_manifest import all_managed_script_names, codex_specs, load_manifest


class HookSpec(dict):
    pass


MANIFEST = load_manifest()
MANAGED_SPECS: list[HookSpec] = [HookSpec(spec) for spec in codex_specs(MANIFEST)]

LEGACY_MARKERS = {
    "pre-bash-guard.sh",
    "post-build-check.sh",
    "stop-guard.sh",
    "learn-evaluator.sh",
    "post-guard-check.sh",
    "session-tagger.sh",
    "cognitive-reminder.sh",
}

MANAGED_MARKERS = LEGACY_MARKERS | all_managed_script_names(MANIFEST)

# Namespaced vibeguard-* script names from MANAGED_SPECS.  These are
# unambiguous enough to identify VibeGuard entries without inspecting the
# wrapper path, so removal works even when a non-standard wrapper is used.
_MANAGED_SCRIPT_NAMES: frozenset[str] = frozenset(spec["script"] for spec in MANAGED_SPECS)
_WRAPPER_NAMES: frozenset[str] = frozenset({"run-hook-codex.sh"})
_STANDALONE_LEGACY_SCRIPTS: frozenset[str] = frozenset(
    {"session-tagger.sh", "cognitive-reminder.sh", "post-guard-check.sh"}
)


def _display_path(path: Path, home: Path) -> str:
    try:
        return "~/" + path.relative_to(home).as_posix()
    except ValueError:
        return str(path)


def _expand_shell_path(token: str, home: Path) -> Path | None:
    if token.startswith("~/"):
        return home / token[2:]
    if token.startswith("$HOME/"):
        return home / token[len("$HOME/"):]
    if token.startswith("${HOME}/"):
        return home / token[len("${HOME}/"):]
    if token.startswith("/"):
        return Path(token)
    return None


def _hook_target_from_command(command: str, home: Path) -> Path | None:
    try:
        parts = shlex.split(command)
    except ValueError:
        return None

    for index, token in enumerate(parts):
        path = _expand_shell_path(token, home)
        if path is None:
            continue
        path_text = path.as_posix()
        if "/.vibeguard/installed/hooks/" in path_text:
            return path
        if path_text.endswith("/.vibeguard/run-hook-codex.sh") and index + 1 < len(parts):
            script_name = parts[index + 1]
            if script_name and "/" not in script_name:
                installed_dir = path.parent / "installed/hooks"
                if installed_dir.exists():
                    return installed_dir / script_name
    return None


def load_hooks(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError("hooks.json root must be an object")
    return data


def save_hooks(path: Path, data: dict[str, Any]) -> None:
    write_json_atomic(path, data)


def _ensure_hooks_root(data: dict[str, Any]) -> dict[str, Any]:
    hooks = data.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        hooks = {}
        data["hooks"] = hooks
    return hooks


def _identity_for_hook(event: str, matcher: str | None, hook: dict[str, Any]) -> Any:
    command = hook.get("command")
    if not isinstance(command, str):
        command = ""
    timeout_value = hook.get("timeout")
    timeout = timeout_value if isinstance(timeout_value, int) else None
    return hook_command_identity(
        platform="codex",
        event=event,
        matcher=matcher,
        command=command,
        timeout=timeout,
        managed_scripts=_MANAGED_SCRIPT_NAMES,
        legacy_scripts=MANAGED_MARKERS,
        wrapper_names=_WRAPPER_NAMES,
        standalone_legacy_scripts=_STANDALONE_LEGACY_SCRIPTS,
    )


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
            matcher_value = entry.get("matcher")
            matcher = matcher_value if isinstance(matcher_value, str) and matcher_value else None

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
                if _identity_for_hook(str(event), matcher, hook).is_managed:
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


def _iter_hook_commands(data: dict[str, Any]) -> list[tuple[str, str, str]]:
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        return []

    commands: list[tuple[str, str, str]] = []
    for event, entries in hooks.items():
        if not isinstance(entries, list):
            continue
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            matcher = entry.get("matcher")
            matcher_text = matcher if isinstance(matcher, str) and matcher else "<none>"
            hook_entries = entry.get("hooks")
            if not isinstance(hook_entries, list):
                continue
            for hook in hook_entries:
                if not isinstance(hook, dict):
                    continue
                command = hook.get("command")
                if isinstance(command, str) and command:
                    commands.append((str(event), matcher_text, command))
    return commands


def stale_hook_findings(path: Path, home: Path) -> list[dict[str, str]]:
    data = load_hooks(path)
    findings: list[dict[str, str]] = []
    for event, matcher, command in _iter_hook_commands(data):
        hook_target = _hook_target_from_command(command, home)
        if hook_target is None or hook_target.exists():
            continue
        findings.append(
            {
                "client": "Codex",
                "config": _display_path(path, home),
                "event": event,
                "matcher": matcher,
                "command_path": str(hook_target),
                "repair": "bash setup.sh --yes",
            }
        )
    return findings


def _prune_stale_installed_hook_entries(data: dict[str, Any], home: Path) -> bool:
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

            kept_hooks: list[Any] = []
            removed_any = False
            for hook in hook_entries:
                if not isinstance(hook, dict):
                    kept_hooks.append(hook)
                    continue
                command = hook.get("command")
                if isinstance(command, str):
                    hook_target = _hook_target_from_command(command, home)
                    if hook_target is not None and not hook_target.exists():
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
        "command": f"bash {shlex.quote(wrapper)} {spec['script']}",
    }
    timeout = spec.get("timeout")
    if isinstance(timeout, int):
        hook["timeout"] = timeout

    entry: dict[str, Any] = {"hooks": [hook]}
    matcher = spec.get("matcher")
    if isinstance(matcher, str) and matcher:
        entry["matcher"] = matcher
    return entry


def _has_entry(
    entries: list[Any],
    expected_command: str,
    expected_matcher: str | None,
    expected_timeout: int | None,
) -> bool:
    """Return True only when a fully-conformant managed entry exists.

    Checks ``command``, ``type``, ``matcher``, and ``timeout`` so that a stale
    entry with the right command but wrong metadata does not block repair.
    """
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        if entry.get("matcher") != expected_matcher:
            continue
        hook_entries = entry.get("hooks")
        if not isinstance(hook_entries, list):
            continue
        for hook in hook_entries:
            if not isinstance(hook, dict):
                continue
            identity = _identity_for_hook("", expected_matcher, hook)
            if not identity.is_managed:
                continue
            if hook.get("command") != expected_command:
                continue
            if hook.get("type") != "command":
                continue
            # timeout must be present-and-matching when the spec demands it,
            # and absent when the spec has none (Stop entries).
            if expected_timeout is not None:
                if hook.get("timeout") != expected_timeout:
                    continue
            else:
                if "timeout" in hook:
                    continue
            return True
    return False


def cmd_upsert_vibeguard(args: argparse.Namespace) -> int:
    hooks_path = Path(args.hooks_file)
    data = load_hooks(hooks_path)
    before = json.dumps(data, sort_keys=True, ensure_ascii=False)

    _ensure_hooks_root(data)
    _prune_vibeguard_entries(data)
    _prune_stale_installed_hook_entries(data, Path.home())
    hooks = _ensure_hooks_root(data)

    for spec in MANAGED_SPECS:
        event = str(spec["event"])
        entries = hooks.setdefault(event, [])
        if not isinstance(entries, list):
            entries = []
            hooks[event] = entries
        expected_command = f"bash {shlex.quote(args.wrapper)} {spec['script']}"
        expected_matcher = spec.get("matcher") if isinstance(spec.get("matcher"), str) else None
        expected_timeout = spec.get("timeout") if isinstance(spec.get("timeout"), int) else None
        if not _has_entry(entries, expected_command, expected_matcher, expected_timeout):
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


def cmd_check_stale_hooks(args: argparse.Namespace) -> int:
    hooks_path = Path(args.hooks_file)
    if not hooks_path.exists():
        return 0
    findings = stale_hook_findings(hooks_path, Path.home())
    for finding in findings:
        print(
            "stale {client} hook command: config={config} event={event} "
            "matcher={matcher} command_path={command_path} repair={repair}".format(**finding)
        )
    return 1 if findings else 0


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

        expected_command = f"bash {shlex.quote(args.wrapper)} {spec['script']}"
        expected_matcher = spec.get("matcher")
        expected_timeout = spec.get("timeout") if isinstance(spec.get("timeout"), int) else None
        if not _has_entry(entries, expected_command, expected_matcher if isinstance(expected_matcher, str) else None, expected_timeout):
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

    stale = sub.add_parser("check-stale-hooks", help="Detect stale hook commands")
    stale.add_argument("--hooks-file", required=True)
    stale.set_defaults(func=cmd_check_stale_hooks)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())

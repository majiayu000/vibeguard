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

from file_ops import write_json_atomic
from hook_config_model import hook_command_identity, normalize_hook_entry
from hooks_manifest import all_managed_script_names, claude_specs, load_manifest


MANIFEST = load_manifest()
MANAGED_SCRIPT_NAMES = all_managed_script_names(MANIFEST)
LEGACY_SCRIPT_NAMES: frozenset[str] = frozenset(
    {"post-guard-check.sh", "session-tagger.sh", "cognitive-reminder.sh"}
)
WRAPPER_NAMES: frozenset[str] = frozenset({"run-hook.sh"})


def load_settings(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError("settings.json root must be an object")
    return data


def save_settings(path: Path, data: dict[str, Any]) -> None:
    write_json_atomic(path, data)


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


def _entry_identities(event: str, entry: Any) -> list[Any]:
    return normalize_hook_entry(
        platform="claude",
        event=event,
        entry=entry,
        managed_scripts=MANAGED_SCRIPT_NAMES,
        legacy_scripts=LEGACY_SCRIPT_NAMES,
        wrapper_names=WRAPPER_NAMES,
        standalone_legacy_scripts=LEGACY_SCRIPT_NAMES,
    )


def _hook_identity(event: str, matcher: str | None, hook: dict[str, Any]) -> Any:
    command = hook.get("command")
    if not isinstance(command, str):
        command = ""
    timeout_value = hook.get("timeout")
    timeout = timeout_value if isinstance(timeout_value, int) else None
    return hook_command_identity(
        platform="claude",
        event=event,
        matcher=matcher,
        command=command,
        timeout=timeout,
        managed_scripts=MANAGED_SCRIPT_NAMES,
        legacy_scripts=LEGACY_SCRIPT_NAMES,
        wrapper_names=WRAPPER_NAMES,
        standalone_legacy_scripts=LEGACY_SCRIPT_NAMES,
    )


def _entry_has_script(event: str, entry: Any, scripts: set[str] | frozenset[str]) -> bool:
    return any(identity.script in scripts for identity in _entry_identities(event, entry))


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
        if path_text.endswith("/.vibeguard/run-hook.sh") and index + 1 < len(parts):
            script_name = parts[index + 1]
            if script_name and "/" not in script_name:
                installed_dir = path.parent / "installed/hooks"
                if installed_dir.exists():
                    return installed_dir / script_name
    return None


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
    data = load_settings(path)
    findings: list[dict[str, str]] = []
    for event, matcher, command in _iter_hook_commands(data):
        hook_target = _hook_target_from_command(command, home)
        if hook_target is None or hook_target.exists():
            continue
        findings.append(
            {
                "client": "Claude",
                "config": _display_path(path, home),
                "event": event,
                "matcher": matcher,
                "command_path": str(hook_target),
                "repair": "bash setup.sh --yes",
            }
        )
    return findings


def _remove_stale_installed_hook_entries(data: dict[str, Any], home: Path) -> bool:
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
        if any(identity.script == spec["script"] for identity in _entry_identities(str(spec["event"]), entry)):
            return True
    return False


def _has_all_specs(data: dict[str, Any], specs: list[dict[str, Any]]) -> bool:
    return all(_has_hook_spec(data, spec) for spec in specs)


def _spec_identity(spec: dict[str, Any]) -> tuple[str, str, str]:
    return (str(spec["event"]), str(spec.get("matcher") or ""), str(spec["script"]))


def _managed_hook_identities(data: dict[str, Any]) -> set[tuple[str, str, str]]:
    hooks = data.get("hooks", {})
    if not isinstance(hooks, dict):
        return set()

    identities: set[tuple[str, str, str]] = set()
    for event, entries in hooks.items():
        if not isinstance(entries, list):
            continue
        for entry in entries:
            for identity in _entry_identities(str(event), entry):
                if identity.is_managed and identity.script:
                    identities.add((identity.event, identity.matcher or "", identity.script))
    return identities


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


def has_profile_hooks(data: dict[str, Any], profile: str) -> bool:
    desired_specs = claude_specs(MANIFEST, profile)
    if not _has_all_specs(data, desired_specs):
        return False
    desired_identities = {_spec_identity(spec) for spec in desired_specs}
    return _managed_hook_identities(data).issubset(desired_identities)


def _hook_command(repo_dir: str, script_name: str) -> str:
    """Generate the hook command using the run-hook.sh wrapper."""
    wrapper = Path.home() / ".vibeguard" / "run-hook.sh"
    return f"bash {shlex.quote(str(wrapper))} {shlex.quote(script_name)}"


def _is_canonical_hook_command(command: str, script_name: str) -> bool:
    try:
        parts = shlex.split(command)
    except ValueError:
        return False
    if len(parts) == 3:
        return (
            parts[0] == "bash"
            and parts[1].endswith("/.vibeguard/run-hook.sh")
            and parts[2] == script_name
        )
    if len(parts) <= 3 or parts[0] != "bash" or parts[-1] != script_name:
        return False
    wrapper_parts = parts[1:-1]
    path_prefixes = ("/", "~/", "$HOME/", "${HOME}/")
    return (
        wrapper_parts[0].startswith(path_prefixes)
        and not any(part.startswith(("-", *path_prefixes)) for part in wrapper_parts[1:])
        and " ".join(wrapper_parts).endswith("/.vibeguard/run-hook.sh")
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
    for event in ("PreToolUse", "PostToolUse", "Stop", "SessionStart"):
        entries = hooks.get(event)
        if not isinstance(entries, list):
            continue

        filtered = [
            entry for entry in entries
            if not _entry_has_script(str(event), entry, LEGACY_SCRIPT_NAMES)
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
    filtered = [e for e in entries if not _entry_has_script(event, e, frozenset({script_name}))]
    if len(filtered) != len(entries):
        if filtered:
            hooks[event] = filtered
        else:
            hooks.pop(event, None)
        state["changed"] = True


def remove_unprofiled_managed_hooks(
    hooks: dict[str, Any],
    desired_identities: set[tuple[str, str, str]],
    state: dict[str, Any],
) -> None:
    for event, entries in list(hooks.items()):
        if not isinstance(entries, list):
            continue

        next_entries: list[Any] = []
        for entry in entries:
            if not isinstance(entry, dict):
                next_entries.append(entry)
                continue

            hook_entries = entry.get("hooks")
            if not isinstance(hook_entries, list):
                next_entries.append(entry)
                continue

            matcher_value = entry.get("matcher")
            matcher = matcher_value if isinstance(matcher_value, str) and matcher_value else None
            kept_hooks: list[Any] = []
            removed_any = False
            for hook in hook_entries:
                if not isinstance(hook, dict):
                    kept_hooks.append(hook)
                    continue
                identity = _hook_identity(str(event), matcher, hook)
                if identity.is_managed and identity.script:
                    hook_identity = (identity.event, identity.matcher or "", identity.script)
                    if hook_identity not in desired_identities:
                        removed_any = True
                        continue
                kept_hooks.append(hook)

            if removed_any:
                state["changed"] = True
                if kept_hooks:
                    next_entry = dict(entry)
                    next_entry["hooks"] = kept_hooks
                    next_entries.append(next_entry)
            else:
                next_entries.append(entry)

        if len(next_entries) != len(entries) or next_entries != entries:
            if next_entries:
                hooks[event] = next_entries
            else:
                hooks.pop(event, None)


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
        identities = _entry_identities(event, entry)
        if matcher:
            if entry.get("matcher") != matcher:
                continue
        elif not any(identity.script == script_name for identity in identities):
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
            matcher_value = entry.get("matcher")
            entry_matcher = matcher_value if isinstance(matcher_value, str) and matcher_value else None
            identity = _hook_identity(event, entry_matcher, hook)
            cmd = hook.get("command", "")
            if identity.script != script_name:
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
    if args.target.startswith("profile-hooks:"):
        profile = args.target.removeprefix("profile-hooks:")
        if profile not in {"minimal", "core", "full", "strict"}:
            print(f"unsupported profile target: {profile}", file=sys.stderr)
            return 2
        return 0 if has_profile_hooks(data, profile) else 1
    print(f"unsupported target: {args.target}", file=sys.stderr)
    return 1


def cmd_check_stale_hooks(args: argparse.Namespace) -> int:
    settings_path = Path(args.settings_file)
    if not settings_path.exists():
        return 0
    findings = stale_hook_findings(settings_path, Path.home())
    for finding in findings:
        print(
            "stale {client} hook command: config={config} event={event} "
            "matcher={matcher} command_path={command_path} repair={repair}".format(**finding)
        )
    return 1 if findings else 0


def cmd_upsert_vibeguard(args: argparse.Namespace) -> int:
    settings_path = Path(args.settings_file)
    before_text = settings_path.read_text(encoding="utf-8") if settings_path.exists() else ""
    data = load_settings(settings_path)
    state: dict[str, Any] = {"changed": False}

    if _remove_legacy_mcp_server(data):
        state["changed"] = True
    if _remove_legacy_hook_entries(data):
        state["changed"] = True
    if _remove_stale_installed_hook_entries(data, Path.home()):
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
    remove_unprofiled_managed_hooks(hooks, {_spec_identity(spec) for spec in desired_specs}, state)

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
        event_scripts: dict[str, frozenset[str]] = {
            "PreToolUse": frozenset(MANAGED_SCRIPT_NAMES),
            "PostToolUse": frozenset(MANAGED_SCRIPT_NAMES | {"post-guard-check.sh"}),
            "Stop": frozenset(MANAGED_SCRIPT_NAMES),
            "SessionStart": frozenset(MANAGED_SCRIPT_NAMES),
            "PreCompact": frozenset(MANAGED_SCRIPT_NAMES),
            "UserPromptSubmit": frozenset(MANAGED_SCRIPT_NAMES),
        }
        for event, scripts in event_scripts.items():
            if event not in hooks or not isinstance(hooks[event], list):
                continue
            original = hooks[event]
            filtered = [
                h for h in original
                if not _entry_has_script(event, h, scripts)
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
    check.add_argument(
        "--target",
        required=True,
        help="pre-hooks, post-hooks, full-hooks, or profile-hooks:<minimal|core|full|strict>",
    )
    check.set_defaults(func=cmd_check)

    stale = sub.add_parser("check-stale-hooks", help="Detect stale hook commands")
    stale.add_argument("--settings-file", required=True)
    stale.set_defaults(func=cmd_check_stale_hooks)

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

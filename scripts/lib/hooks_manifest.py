#!/usr/bin/env python3
"""Single source of truth helpers for VibeGuard hook registration."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_MANIFEST = ROOT / "hooks" / "manifest.json"
PROFILE_ORDER = ("minimal", "core", "full", "strict")
DISABLEABLE_KINDS = {"hook", "git-hook"}
HOOK_EVENTS = {
    "PreToolUse",
    "PermissionRequest",
    "PostToolUse",
    "Stop",
    "SessionStart",
    "PreCompact",
    "PostCompact",
    "UserPromptSubmit",
}


def _script_path_is_safe(script: str) -> bool:
    path = Path(script)
    return not path.is_absolute() and ".." not in path.parts and all(path.parts)


def _validate_script(
    script: Any,
    kind: Any,
    prefix: str,
    repo_root: Path,
) -> tuple[str | None, list[str]]:
    errors: list[str] = []
    if not isinstance(script, str) or not script:
        return None, [f"{prefix}.script must be a non-empty string"]
    if not _script_path_is_safe(script):
        return script, [f"{prefix}.script must be a safe hooks-relative path"]
    if kind != "git-hook" and ("/" in script or not script.endswith(".sh")):
        errors.append(f"{prefix}.script must be a shell script name")
    if kind == "git-hook" and not (script.endswith(".sh") or "/" in script):
        errors.append(f"{prefix}.script must be a shell script name or git hook path")
    if not (repo_root / "hooks" / script).is_file():
        errors.append(f"{prefix}.script missing hooks/{script}")
    return script, errors


def _git_hook_sources(repo_root: Path) -> set[str]:
    git_hooks_dir = repo_root / "hooks" / "git"
    if not git_hooks_dir.is_dir():
        return set()
    return {
        f"git/{path.name}"
        for path in git_hooks_dir.iterdir()
        if path.is_file() and not path.name.startswith(".")
    }


def load_manifest(path: Path = DEFAULT_MANIFEST) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError("hooks manifest root must be an object")
    return data


def hooks(data: dict[str, Any]) -> list[dict[str, Any]]:
    items = data.get("hooks")
    if not isinstance(items, list):
        raise ValueError("hooks manifest must contain a hooks array")
    result: list[dict[str, Any]] = []
    for item in items:
        if not isinstance(item, dict):
            raise ValueError("each hook manifest entry must be an object")
        result.append(item)
    return result


def claude_specs(data: dict[str, Any], profile: str | None = None) -> list[dict[str, Any]]:
    specs: list[dict[str, Any]] = []
    for item in hooks(data):
        claude = item.get("claude")
        if not isinstance(claude, dict) or not claude.get("enabled"):
            continue
        profiles = claude.get("profiles", [])
        if profile is not None and profile not in profiles:
            continue
        matchers = claude.get("matchers", [])
        if not isinstance(matchers, list) or not matchers:
            raise ValueError(f"{item.get('name', '<unknown>')}: claude.matchers must be a non-empty array")
        for matcher in matchers:
            specs.append(
                {
                    "name": item["name"],
                    "event": claude["event"],
                    "matcher": matcher if matcher is not None else "",
                    "script": item["script"],
                    "profiles": profiles,
                }
            )
    return specs


def codex_specs(data: dict[str, Any]) -> list[dict[str, Any]]:
    specs: list[dict[str, Any]] = []
    for item in hooks(data):
        codex = item.get("codex")
        if not isinstance(codex, dict) or not codex.get("enabled"):
            continue
        entries = codex.get("entries")
        if isinstance(entries, list):
            for entry in entries:
                if not isinstance(entry, dict):
                    raise ValueError(f"{item.get('name', '<unknown>')}: codex.entries must contain objects")
                spec: dict[str, Any] = {
                    "name": item["name"],
                    "event": entry["event"],
                    "matcher": entry.get("matcher"),
                    "script": entry.get("script", codex.get("script")),
                }
                if isinstance(entry.get("timeout"), int):
                    spec["timeout"] = entry["timeout"]
                elif isinstance(codex.get("timeout"), int):
                    spec["timeout"] = codex["timeout"]
                specs.append(spec)
        else:
            spec = {
                "name": item["name"],
                "event": codex["event"],
                "matcher": codex.get("matcher"),
                "script": codex["script"],
            }
            if isinstance(codex.get("timeout"), int):
                spec["timeout"] = codex["timeout"]
            specs.append(spec)
    return specs


def all_managed_script_names(data: dict[str, Any]) -> set[str]:
    names: set[str] = set()
    for item in hooks(data):
        script = item.get("script")
        if isinstance(script, str):
            names.add(script)
        codex = item.get("codex")
        if isinstance(codex, dict) and isinstance(codex.get("script"), str):
            names.add(codex["script"])
    return names


def disableable_hook_names(data: dict[str, Any]) -> list[str]:
    names: list[str] = []
    for item in hooks(data):
        exposure = item.get("config_exposure")
        if not isinstance(exposure, dict) or exposure.get("disabled_hook") is not True:
            continue
        name = item.get("name")
        if isinstance(name, str):
            names.append(name)
    return sorted(names)


def _validate_event(value: Any, path: str) -> None:
    if value not in HOOK_EVENTS:
        raise ValueError(f"{path} must be one of {sorted(HOOK_EVENTS)}")


def _validate_profiles(value: Any, path: str) -> None:
    if not isinstance(value, list) or not value:
        raise ValueError(f"{path} must be a non-empty array")
    unknown = [p for p in value if p not in PROFILE_ORDER]
    if unknown:
        raise ValueError(f"{path} contains unknown profiles: {unknown}")


def validate_manifest(data: dict[str, Any], repo_root: Path = ROOT) -> list[str]:
    errors: list[str] = []
    names: set[str] = set()
    git_hook_scripts: set[str] = set()

    if data.get("schema_version") != 1:
        errors.append("schema_version must be 1")

    try:
        items = hooks(data)
    except ValueError as exc:
        return [str(exc)]

    for index, item in enumerate(items):
        prefix = f"hooks[{index}]"
        name = item.get("name")
        script = item.get("script")
        if not isinstance(name, str) or not name:
            errors.append(f"{prefix}.name must be a non-empty string")
            name = f"<invalid-{index}>"
        elif name in names:
            errors.append(f"{prefix}.name duplicates {name}")
        else:
            names.add(name)

        kind = item.get("kind")
        script, script_errors = _validate_script(script, kind, prefix, repo_root)
        errors.extend(script_errors)
        if kind == "git-hook" and isinstance(script, str):
            git_hook_scripts.add(script)

        if kind in DISABLEABLE_KINDS:
            install_targets = item.get("install_targets")
            if not isinstance(install_targets, list):
                errors.append(f"{prefix}.install_targets must be an array")
            elif not all(isinstance(target, str) and target for target in install_targets):
                errors.append(f"{prefix}.install_targets must contain non-empty strings")
            exposure = item.get("config_exposure")
            if not isinstance(exposure, dict):
                errors.append(f"{prefix}.config_exposure must be an object")
            elif not isinstance(exposure.get("disabled_hook"), bool):
                errors.append(f"{prefix}.config_exposure.disabled_hook must be boolean")

        for platform in ("claude", "codex"):
            platform_data = item.get(platform)
            if not isinstance(platform_data, dict):
                errors.append(f"{prefix}.{platform} must be an object")
                continue
            enabled = platform_data.get("enabled")
            if not isinstance(enabled, bool):
                errors.append(f"{prefix}.{platform}.enabled must be boolean")
                continue
            if not enabled:
                continue
            try:
                codex_entries = platform_data.get("entries") if platform == "codex" else None
                if platform != "codex" or not isinstance(codex_entries, list):
                    _validate_event(platform_data.get("event"), f"{prefix}.{platform}.event")
                if platform == "claude":
                    _validate_profiles(platform_data.get("profiles"), f"{prefix}.claude.profiles")
                    matchers = platform_data.get("matchers")
                    if not isinstance(matchers, list) or not matchers:
                        errors.append(f"{prefix}.claude.matchers must be a non-empty array")
                if platform == "codex":
                    entries = codex_entries
                    if isinstance(entries, list):
                        if not entries:
                            errors.append(f"{prefix}.codex.entries must be a non-empty array")
                        for entry_index, entry in enumerate(entries):
                            entry_prefix = f"{prefix}.codex.entries[{entry_index}]"
                            if not isinstance(entry, dict):
                                errors.append(f"{entry_prefix} must be an object")
                                continue
                            try:
                                _validate_event(entry.get("event"), f"{entry_prefix}.event")
                            except ValueError as exc:
                                errors.append(str(exc))
                            codex_script = entry.get("script", platform_data.get("script"))
                            if not isinstance(codex_script, str) or not codex_script.startswith("vibeguard-"):
                                errors.append(f"{entry_prefix}.script must be a namespaced vibeguard-* script")
                            elif not (repo_root / "hooks" / codex_script).exists():
                                errors.append(f"{entry_prefix}.script missing hooks/{codex_script}")
                    else:
                        codex_script = platform_data.get("script")
                        if not isinstance(codex_script, str) or not codex_script.startswith("vibeguard-"):
                            errors.append(f"{prefix}.codex.script must be a namespaced vibeguard-* script")
                        elif not (repo_root / "hooks" / codex_script).exists():
                            errors.append(f"{prefix}.codex.script missing hooks/{codex_script}")
            except ValueError as exc:
                errors.append(str(exc))

    missing_git_hooks = sorted(_git_hook_sources(repo_root) - git_hook_scripts)
    for script in missing_git_hooks:
        errors.append(f"hooks/{script} missing from hooks manifest")

    return errors


def render_doc_table(data: dict[str, Any]) -> str:
    lines = [
        "| Documentation | Trigger Timing | Responsibilities | Codex |",
        "|------|----------|------|-------|",
    ]
    for item in hooks(data):
        codex = item.get("codex", {})
        if not isinstance(codex, dict):
            codex = {}
        support = str(codex.get("support", "not-applicable"))
        codex_cell = {
            "native": "native",
            "unsupported": "unsupported",
            "manual": "manual",
            "not-applicable": "-",
        }.get(support, support)
        lines.append(
            "| `{script}` | {trigger} | {responsibilities} | {codex} |".format(
                script=item.get("script", ""),
                trigger=item.get("trigger", ""),
                responsibilities=item.get("responsibilities", ""),
                codex=codex_cell,
            )
        )
    return "\n".join(lines) + "\n"


def _print_json(items: Iterable[dict[str, Any]]) -> None:
    print(json.dumps(list(items), indent=2, ensure_ascii=False))


def cmd_validate(args: argparse.Namespace) -> int:
    manifest = load_manifest(Path(args.manifest))
    errors = validate_manifest(manifest, ROOT)
    if errors:
        for error in errors:
            print(f"FAIL: {error}")
        return 1
    print("OK: hooks manifest valid")
    return 0


def cmd_render_doc_table(args: argparse.Namespace) -> int:
    manifest = load_manifest(Path(args.manifest))
    print(render_doc_table(manifest), end="")
    return 0


def cmd_codex_specs(args: argparse.Namespace) -> int:
    _print_json(codex_specs(load_manifest(Path(args.manifest))))
    return 0


def cmd_disableable_hook_names(args: argparse.Namespace) -> int:
    for name in disableable_hook_names(load_manifest(Path(args.manifest))):
        print(name)
    return 0


def cmd_claude_specs(args: argparse.Namespace) -> int:
    _print_json(claude_specs(load_manifest(Path(args.manifest)), args.profile))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="VibeGuard hooks manifest helper")
    parser.add_argument("--manifest", default=str(DEFAULT_MANIFEST))
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("validate").set_defaults(func=cmd_validate)
    sub.add_parser("render-doc-table").set_defaults(func=cmd_render_doc_table)
    sub.add_parser("codex-specs").set_defaults(func=cmd_codex_specs)
    sub.add_parser("disableable-hook-names").set_defaults(func=cmd_disableable_hook_names)

    claude = sub.add_parser("claude-specs")
    claude.add_argument("--profile", choices=PROFILE_ORDER)
    claude.set_defaults(func=cmd_claude_specs)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())

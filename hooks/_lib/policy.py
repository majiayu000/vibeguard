#!/usr/bin/env python3
"""Runtime policy gate for VibeGuard hook wrappers."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any


ALLOW = 0
SKIP = 10
POLICY_ERROR = 20
CONFIG_PARSE_ERROR = 30


class PolicyFailure(Exception):
    def __init__(self, message: str, exit_code: int = POLICY_ERROR) -> None:
        super().__init__(message)
        self.exit_code = exit_code


def _runtime_root() -> Path:
    override = os.environ.get("VIBEGUARD_POLICY_ROOT")
    if override:
        return Path(override)
    return Path(__file__).resolve().parents[2]


def _load_json(path: Path, label: str) -> Any:
    try:
        with path.open(encoding="utf-8") as f:
            return json.load(f)
    except UnicodeDecodeError as exc:
        raise PolicyFailure(
            f"VibeGuard {label} invalid UTF-8: {path}: {exc}",
            CONFIG_PARSE_ERROR,
        ) from exc
    except json.JSONDecodeError as exc:
        raise PolicyFailure(
            f"VibeGuard {label} invalid JSON: {path}: line {exc.lineno}, column {exc.colno}: {exc.msg}",
            CONFIG_PARSE_ERROR,
        ) from exc
    except OSError as exc:
        raise PolicyFailure(f"VibeGuard {label} cannot be read: {path}: {exc}") from exc


def _project_config_path() -> Path | None:
    configured = os.environ.get("VIBEGUARD_PROJECT_CONFIG", "")
    if configured:
        path = Path(configured)
        return path if path.is_file() else None

    cwd = Path.cwd().resolve()
    try:
        git_root = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            cwd=cwd,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        ).stdout.strip()
    except OSError:
        git_root = ""

    if git_root:
        candidate = Path(git_root) / ".vibeguard.json"
        if candidate.is_file():
            return candidate

    candidate = cwd / ".vibeguard.json"
    if candidate.is_file():
        return candidate
    return None


def _validate_project_config(root: Path, path: Path) -> dict[str, Any]:
    scripts_lib = root / "scripts" / "lib"
    schema_path = root / "schemas" / "vibeguard-project.schema.json"
    validator_path = scripts_lib / "project_config_validate.py"
    if not schema_path.is_file():
        raise PolicyFailure(f"VibeGuard policy error: project schema missing at {schema_path}")
    if not validator_path.is_file():
        raise PolicyFailure(f"VibeGuard policy error: project config validator missing at {validator_path}")

    sys.path.insert(0, str(scripts_lib))
    try:
        import project_config_validate  # type: ignore[import-not-found]
    except Exception as exc:
        raise PolicyFailure(f"VibeGuard policy error: cannot load project config validator: {exc}") from exc

    config = _load_json(path, "project config")
    schema = _load_json(schema_path, "project schema")
    errors = project_config_validate.validate(config, schema)
    if errors:
        lines = [f"VibeGuard project config invalid: {path}"]
        lines.extend(f"  {error}" for error in errors)
        raise PolicyFailure("\n".join(lines))
    return config


def _validate_user_config(path_text: str) -> None:
    if not path_text:
        return
    path = Path(path_text)
    if not path.is_file():
        return
    _load_json(path, "runtime config")


def _load_manifest(root: Path) -> dict[str, Any]:
    manifest_path = root / "hooks" / "manifest.json"
    if not manifest_path.is_file():
        raise PolicyFailure(f"VibeGuard policy error: hooks manifest missing at {manifest_path}")
    manifest = _load_json(manifest_path, "hooks manifest")
    if not isinstance(manifest, dict):
        raise PolicyFailure(f"VibeGuard policy error: hooks manifest must be an object: {manifest_path}")
    return manifest


def _hook_entries(manifest: dict[str, Any]) -> list[dict[str, Any]]:
    entries = manifest.get("hooks")
    if not isinstance(entries, list):
        raise PolicyFailure("VibeGuard policy error: hooks manifest must contain a hooks array")
    return [entry for entry in entries if isinstance(entry, dict)]


def _script_names(entry: dict[str, Any]) -> set[str]:
    names: set[str] = set()
    script = entry.get("script")
    if isinstance(script, str):
        names.add(script)

    codex = entry.get("codex")
    if isinstance(codex, dict):
        codex_script = codex.get("script")
        if isinstance(codex_script, str):
            names.add(codex_script)
        entries = codex.get("entries")
        if isinstance(entries, list):
            for codex_entry in entries:
                if not isinstance(codex_entry, dict):
                    continue
                entry_script = codex_entry.get("script")
                if isinstance(entry_script, str):
                    names.add(entry_script)
    return names


def _canonical_hook(hook_name: str, manifest: dict[str, Any]) -> tuple[str, dict[str, Any] | None]:
    hook_file = Path(hook_name).name
    hook_stem = hook_file[:-3] if hook_file.endswith(".sh") else hook_file
    for entry in _hook_entries(manifest):
        name = entry.get("name")
        if not isinstance(name, str):
            continue
        if hook_name == name or hook_file in _script_names(entry) or hook_stem == name:
            return name, entry
    return hook_stem.removeprefix("vibeguard-").replace("_", "-"), None


def _profile_allows(profile: str | None, entry: dict[str, Any] | None) -> bool:
    if not profile or entry is None:
        return True
    claude = entry.get("claude")
    if not isinstance(claude, dict):
        return True
    profiles = claude.get("profiles")
    if not isinstance(profiles, list):
        return True
    return profile in profiles


def check_policy(hook_name: str, user_config: str) -> tuple[int, str]:
    root = _runtime_root()
    _validate_user_config(user_config)

    project_config_file = _project_config_path()
    if project_config_file is None:
        return ALLOW, ""

    config = _validate_project_config(root, project_config_file)
    manifest = _load_manifest(root)
    canonical_hook, manifest_entry = _canonical_hook(hook_name, manifest)

    enforcement = config.get("enforcement", "block")
    if enforcement == "off":
        return SKIP, "VibeGuard policy skip: enforcement=off"
    if enforcement == "warn":
        return ALLOW, "VibeGuard policy warn: enforcement=warn"

    disabled_hooks = config.get("disabled_hooks", [])
    if isinstance(disabled_hooks, list) and canonical_hook in disabled_hooks:
        return SKIP, f"VibeGuard policy skip: disabled_hooks contains {canonical_hook}"

    profile = config.get("profile")
    if isinstance(profile, str) and not _profile_allows(profile, manifest_entry):
        return SKIP, f"VibeGuard policy skip: profile={profile} excludes {canonical_hook}"

    return ALLOW, ""


def main() -> int:
    parser = argparse.ArgumentParser(description="Evaluate runtime VibeGuard hook policy")
    subparsers = parser.add_subparsers(dest="command", required=True)
    check = subparsers.add_parser("check")
    check.add_argument("hook_name")
    check.add_argument("--user-config", default=os.environ.get("VIBEGUARD_USER_CONFIG_FILE", ""))
    args = parser.parse_args()

    if args.command == "check":
        try:
            status, message = check_policy(args.hook_name, args.user_config)
        except PolicyFailure as exc:
            print(str(exc), file=sys.stderr)
            return exc.exit_code
        if message:
            print(message)
        return status
    return POLICY_ERROR


if __name__ == "__main__":
    raise SystemExit(main())

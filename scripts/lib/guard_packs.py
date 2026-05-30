#!/usr/bin/env python3
"""Guard Pack manifest helper.

Guard Packs are an adoption layer over existing VibeGuard hooks and rules.
They do not redefine Core behavior; every pack must point back to source-of-truth
files that already exist in the repository.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import sys
from pathlib import Path, PurePosixPath
from typing import Any, Iterable

from guard_pack_receipts import (
    ReceiptError,
    assert_receipt_path_safe,
    build_receipt,
    load_install_receipt,
    remove_install_receipt,
    receipt_file_for_pack,
    receipt_path_for_pack,
    validate_install_receipt,
    write_install_receipt,
)

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - Python < 3.11
    try:
        import tomli as tomllib
    except ModuleNotFoundError:  # pragma: no cover - pip vendor fallback
        from pip._vendor import tomli as tomllib


ROOT = Path(__file__).resolve().parents[2]
PACKS_DIR = ROOT / "packs"
DEFAULT_PACK_MANIFEST = "pack.yaml"
PACK_ID_RE = re.compile(r"^[a-z][a-z0-9-]*$")
SUPPORTED_TARGETS = {"claude-code", "codex", "generic-cli"}
SUPPORTED_TARGET_MODES = {"native", "partial", "unsupported"}
SUPPORTED_STATUSES = {"experimental", "stable", "deprecated"}
SUPPORTED_PROFILES = {"minimal", "core", "full", "strict"}
SUPPORTED_AUDIT_KINDS = {
    "file_exists",
    "file_executable",
    "claude_hook",
    "codex_hook",
    "codex_feature",
}
CLAUDE_WRAPPER_NAMES = frozenset({"run-hook.sh"})
CODEX_WRAPPER_NAMES = frozenset({"run-hook-codex.sh"})
SHELL_NAMES = frozenset({"bash", "sh", "zsh"})


class PackError(ValueError):
    """User-facing pack manifest error."""


def load_pack_data(path: Path) -> dict[str, Any]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise PackError(f"cannot read pack manifest {path}: {exc}") from exc

    try:
        data = json.loads(text)
    except json.JSONDecodeError as json_exc:
        try:
            import yaml  # type: ignore[import-not-found]
        except Exception as yaml_import_exc:  # pragma: no cover - dependency fallback
            raise PackError(
                f"{path} is not JSON-compatible YAML and PyYAML is unavailable: {json_exc}"
            ) from yaml_import_exc
        try:
            data = yaml.safe_load(text)
        except Exception as yaml_exc:
            raise PackError(f"cannot parse pack manifest {path}: {yaml_exc}") from yaml_exc

    if not isinstance(data, dict):
        raise PackError(f"{path}: pack manifest root must be an object")
    return data


def discover_pack_paths(packs_dir: Path = PACKS_DIR) -> list[Path]:
    if not packs_dir.exists():
        return []
    paths: list[Path] = []
    for child in sorted(packs_dir.iterdir()):
        if not child.is_dir():
            continue
        manifest = child / DEFAULT_PACK_MANIFEST
        if manifest.exists():
            paths.append(manifest)
    return paths


def pack_manifest_path(pack_id: str, packs_dir: Path = PACKS_DIR) -> Path:
    if not PACK_ID_RE.match(pack_id):
        raise PackError(f"invalid pack id: {pack_id}")
    return packs_dir / pack_id / DEFAULT_PACK_MANIFEST


def require_str(data: dict[str, Any], key: str, errors: list[str]) -> str:
    value = data.get(key)
    if not isinstance(value, str) or not value.strip():
        errors.append(f"{key}: expected non-empty string")
        return ""
    return value


def require_list(data: dict[str, Any], key: str, errors: list[str]) -> list[Any]:
    value = data.get(key)
    if not isinstance(value, list):
        errors.append(f"{key}: expected list")
        return []
    return value


def require_dict(data: dict[str, Any], key: str, errors: list[str]) -> dict[str, Any]:
    value = data.get(key)
    if not isinstance(value, dict):
        errors.append(f"{key}: expected object")
        return {}
    return value


def normalize_repo_path(path_str: str, context: str) -> str:
    if "\\" in path_str:
        raise PackError(f"{context}: path must use forward slashes: {path_str}")
    path = PurePosixPath(path_str)
    if path.is_absolute():
        raise PackError(f"{context}: path must be repo-relative: {path_str}")
    if ".." in path.parts:
        raise PackError(f"{context}: path must not contain '..': {path_str}")
    normalized = path.as_posix()
    if normalized in {"", "."}:
        raise PackError(f"{context}: path must name a file or directory: {path_str}")
    return normalized


def validate_path_list(items: Any, context: str, errors: list[str]) -> None:
    if not isinstance(items, list):
        errors.append(f"{context}: expected list")
        return
    for item in items:
        if not isinstance(item, str):
            errors.append(f"{context}: path entries must be strings")
            continue
        try:
            normalized = normalize_repo_path(item, context)
        except PackError as exc:
            errors.append(str(exc))
            continue
        if not (ROOT / normalized).exists():
            errors.append(f"{context}: missing path {normalized}")


def validate_targets(data: dict[str, Any], errors: list[str]) -> None:
    targets = require_dict(data, "targets", errors)
    if not targets:
        return
    unknown = sorted(set(targets) - SUPPORTED_TARGETS)
    if unknown:
        errors.append(f"targets: unsupported target ids {unknown}")
    for target_id, target in sorted(targets.items()):
        if not isinstance(target, dict):
            errors.append(f"targets.{target_id}: expected object")
            continue
        mode = target.get("support")
        if mode not in SUPPORTED_TARGET_MODES:
            errors.append(
                f"targets.{target_id}.support: expected one of {sorted(SUPPORTED_TARGET_MODES)}"
            )
        for key in ("surfaces", "would_modify", "would_install", "limitations"):
            value = target.get(key, [])
            if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
                errors.append(f"targets.{target_id}.{key}: expected list of strings")
        audit_checks = target.get("audit_checks", [])
        if not isinstance(audit_checks, list):
            errors.append(f"targets.{target_id}.audit_checks: expected list")
            continue
        for index, check in enumerate(audit_checks):
            context = f"targets.{target_id}.audit_checks[{index}]"
            if not isinstance(check, dict):
                errors.append(f"{context}: expected object")
                continue
            check_id = check.get("id")
            if not isinstance(check_id, str) or not check_id:
                errors.append(f"{context}.id: expected non-empty string")
            kind = check.get("kind")
            if kind not in SUPPORTED_AUDIT_KINDS:
                errors.append(f"{context}.kind: expected one of {sorted(SUPPORTED_AUDIT_KINDS)}")
            path = check.get("path")
            if not isinstance(path, str) or not path.startswith("~/"):
                errors.append(f"{context}.path: expected home-relative path starting with ~/")
            if kind in {"claude_hook", "codex_hook"}:
                for key in ("event", "matcher", "script"):
                    value = check.get(key)
                    if not isinstance(value, str) or not value:
                        errors.append(f"{context}.{key}: expected non-empty string")
            if kind == "codex_feature":
                feature = check.get("feature")
                if not isinstance(feature, str) or not feature:
                    errors.append(f"{context}.feature: expected non-empty string")
                if not isinstance(check.get("expected"), bool):
                    errors.append(f"{context}.expected: expected boolean")


def validate_profiles(data: dict[str, Any], errors: list[str]) -> None:
    profiles = require_dict(data, "profiles", errors)
    if not profiles:
        return
    allowed = profiles.get("allowed")
    default = profiles.get("default")
    if not isinstance(allowed, list) or not all(isinstance(item, str) for item in allowed):
        errors.append("profiles.allowed: expected list of strings")
        return
    unknown = sorted(set(allowed) - SUPPORTED_PROFILES)
    if unknown:
        errors.append(f"profiles.allowed: unsupported profiles {unknown}")
    if default not in allowed:
        errors.append("profiles.default: must be included in profiles.allowed")


def validate_behavior(data: dict[str, Any], errors: list[str]) -> None:
    behavior = require_dict(data, "behavior", errors)
    if not behavior:
        return
    if behavior.get("modifies_project_files") is not False:
        errors.append("behavior.modifies_project_files: safe adoption packs must declare false")
    if behavior.get("default_decision") not in {"block", "warn", "pass", "gate"}:
        errors.append("behavior.default_decision: expected block/warn/pass/gate")
    if not isinstance(behavior.get("fail_mode"), str):
        errors.append("behavior.fail_mode: expected string")


def validate_pack(data: dict[str, Any], manifest_path: Path) -> list[str]:
    errors: list[str] = []
    schema_version = data.get("schema_version")
    if schema_version != 1:
        errors.append("schema_version: expected 1")

    pack_id = require_str(data, "id", errors)
    if pack_id and not PACK_ID_RE.match(pack_id):
        errors.append("id: expected lowercase kebab-case")
    if pack_id and manifest_path.parent.name != pack_id:
        errors.append(f"id: must match directory name {manifest_path.parent.name!r}")

    for key in ("version", "display_name", "summary", "adoption_layer_statement"):
        require_str(data, key, errors)

    status = data.get("status")
    if status not in SUPPORTED_STATUSES:
        errors.append(f"status: expected one of {sorted(SUPPORTED_STATUSES)}")

    if data.get("adoption_layer_only") is not True:
        errors.append("adoption_layer_only: expected true")

    source_of_truth = require_dict(data, "source_of_truth", errors)
    for key, value in sorted(source_of_truth.items()):
        validate_path_list(value, f"source_of_truth.{key}", errors)

    validate_targets(data, errors)
    validate_profiles(data, errors)
    validate_behavior(data, errors)

    demo = require_dict(data, "demo", errors)
    if demo:
        for key in ("command", "blocked_example", "expected_decision", "expected_reason_contains"):
            require_str(demo, key, errors)
        if demo.get("executes_user_command") is not False:
            errors.append("demo.executes_user_command: expected false")

    tests = require_list(data, "tests", errors)
    for index, test in enumerate(tests):
        if not isinstance(test, dict):
            errors.append(f"tests[{index}]: expected object")
            continue
        for key in ("name", "fixture", "expected_decision"):
            require_str(test, key, errors)
        fixture = test.get("fixture")
        if isinstance(fixture, str):
            try:
                normalized = normalize_repo_path(fixture, f"tests[{index}].fixture")
            except PackError as exc:
                errors.append(str(exc))
                continue
            path = ROOT / normalized
            if not path.exists():
                errors.append(f"tests[{index}].fixture: missing path {normalized}")
            elif path.suffix == ".json":
                try:
                    json.loads(path.read_text(encoding="utf-8"))
                except json.JSONDecodeError as exc:
                    errors.append(f"tests[{index}].fixture: invalid JSON: {exc}")
    return errors


def load_pack(pack_id: str, packs_dir: Path = PACKS_DIR) -> tuple[Path, dict[str, Any]]:
    manifest_path = pack_manifest_path(pack_id, packs_dir)
    if not manifest_path.exists():
        raise PackError(f"unknown guard pack: {pack_id}")
    data = load_pack_data(manifest_path)
    errors = validate_pack(data, manifest_path)
    if errors:
        raise PackError("\n".join(f"{manifest_path}: {error}" for error in errors))
    return manifest_path, data


def iter_packs(packs_dir: Path = PACKS_DIR) -> Iterable[tuple[Path, dict[str, Any]]]:
    for path in discover_pack_paths(packs_dir):
        yield path, load_pack_data(path)


def target_for_pack(pack: dict[str, Any], target_id: str) -> dict[str, Any]:
    target = pack["targets"].get(target_id)
    if target is None:
        raise PackError(f"pack {pack['id']} does not declare target {target_id}")
    if target["support"] == "unsupported":
        raise PackError(f"target {target_id} is unsupported for pack {pack['id']}")
    return target


def validate_profile(pack: dict[str, Any], profile: str) -> None:
    if profile not in pack["profiles"]["allowed"]:
        raise PackError(f"unsupported profile for pack {pack['id']}: {profile}")


def validate_install_target(pack: dict[str, Any], target_id: str, target: dict[str, Any]) -> None:
    if target["support"] != "native":
        raise PackError(f"target {target_id} does not support install receipts for pack {pack['id']}")


def expand_home_path(path_text: str, home: Path) -> Path:
    if path_text.startswith("~/"):
        return home / path_text[2:]
    return Path(path_text)


def display_home_path(path: Path, home: Path) -> str:
    try:
        return "~/" + path.resolve().relative_to(home.resolve()).as_posix()
    except ValueError:
        return str(path)


def audit_result(check: dict[str, Any], status: str, detail: str, home: Path) -> dict[str, str]:
    path_text = str(check.get("path", ""))
    path = expand_home_path(path_text, home) if path_text else home
    return {
        "id": str(check.get("id", "<unknown>")),
        "kind": str(check.get("kind", "<unknown>")),
        "status": status,
        "path": display_home_path(path, home),
        "detail": detail,
    }


def load_json_object(path: Path) -> tuple[dict[str, Any] | None, str | None]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None, "missing"
    except UnicodeDecodeError:
        return None, "invalid UTF-8"
    except json.JSONDecodeError as exc:
        return None, f"invalid JSON: {exc.msg}"
    if not isinstance(data, dict):
        return None, "JSON root is not an object"
    return data, None


def hook_config_has_script(
    data: dict[str, Any],
    *,
    event: str,
    matcher: str,
    script: str,
    platform: str,
) -> bool:
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        return False
    entries = hooks.get(event)
    if not isinstance(entries, list):
        return False
    for entry in entries:
        if not isinstance(entry, dict) or entry.get("matcher") != matcher:
            continue
        hook_entries = entry.get("hooks")
        if not isinstance(hook_entries, list):
            continue
        for hook in hook_entries:
            if not isinstance(hook, dict):
                continue
            if hook.get("type") != "command":
                continue
            command = hook.get("command")
            if not isinstance(command, str):
                continue
            wrappers = CLAUDE_WRAPPER_NAMES if platform == "claude" else CODEX_WRAPPER_NAMES
            if command_invokes_script(command, script, wrappers):
                return True
    return False


def is_path_like_command_token(token: str) -> bool:
    return (
        "/" in token
        or token.startswith(("./", "../", "~/", "$HOME/", "${HOME}/"))
        or Path(token).is_absolute()
    )


def command_invokes_script(command: str, script: str, wrapper_names: frozenset[str]) -> bool:
    try:
        parts = shlex.split(command)
    except ValueError:
        return False
    for index, token in enumerate(parts):
        token_base = Path(token).name
        if token_base in wrapper_names and index + 1 < len(parts):
            next_script = Path(parts[index + 1]).name
            if next_script == script and token_is_invoked(parts, index):
                return True
        if token_base == script and token_is_invoked(parts, index):
            return True
    return False


def token_is_invoked(parts: list[str], index: int) -> bool:
    if index > 0 and Path(parts[index - 1]).name in SHELL_NAMES:
        return True
    return index == 0 and is_path_like_command_token(parts[index])


def audit_hook_json(check: dict[str, Any], home: Path, client: str) -> dict[str, str]:
    path = expand_home_path(str(check["path"]), home)
    data, error = load_json_object(path)
    if data is None:
        status = "MISSING" if error == "missing" else "INVALID"
        return audit_result(check, status, f"{client} hook config {error}", home)
    found = hook_config_has_script(
        data,
        event=str(check["event"]),
        matcher=str(check["matcher"]),
        script=str(check["script"]),
        platform=client.lower(),
    )
    if found:
        detail = f"{client} config includes {check['event']}({check['matcher']}) {check['script']}"
        return audit_result(check, "OK", detail, home)
    detail = f"{client} config lacks {check['event']}({check['matcher']}) {check['script']}"
    return audit_result(check, "MISSING", detail, home)


def audit_codex_feature(check: dict[str, Any], home: Path) -> dict[str, str]:
    path = expand_home_path(str(check["path"]), home)
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return audit_result(check, "MISSING", "Codex config missing", home)
    except UnicodeDecodeError:
        return audit_result(check, "INVALID", "Codex config invalid UTF-8", home)
    try:
        data = tomllib.loads(text)
    except tomllib.TOMLDecodeError as exc:
        return audit_result(check, "INVALID", f"Codex config invalid TOML: {exc}", home)
    features = data.get("features")
    actual = features.get(check["feature"]) if isinstance(features, dict) else None
    if actual is check["expected"]:
        return audit_result(check, "OK", f"Codex feature {check['feature']} is {actual}", home)
    detail = f"Codex feature {check['feature']} expected {check['expected']} but found {actual}"
    return audit_result(check, "MISSING", detail, home)


def run_audit_check(check: dict[str, Any], home: Path) -> dict[str, str]:
    path = expand_home_path(str(check["path"]), home)
    kind = check["kind"]
    if kind == "file_exists":
        if path.exists():
            return audit_result(check, "OK", "file exists", home)
        return audit_result(check, "MISSING", "file is missing", home)
    if kind == "file_executable":
        if path.is_file() and os.access(path, os.X_OK):
            return audit_result(check, "OK", "file is executable", home)
        if path.exists():
            return audit_result(check, "INVALID", "file exists but is not executable", home)
        return audit_result(check, "MISSING", "file is missing", home)
    if kind == "claude_hook":
        return audit_hook_json(check, home, "Claude")
    if kind == "codex_hook":
        return audit_hook_json(check, home, "Codex")
    if kind == "codex_feature":
        return audit_codex_feature(check, home)
    return audit_result(check, "INVALID", f"unsupported audit kind: {kind}", home)


def build_audit(pack: dict[str, Any], target_id: str, home: Path) -> dict[str, Any]:
    target = target_for_pack(pack, target_id)
    checks = [run_audit_check(check, home) for check in target.get("audit_checks", [])]
    ready = all(check["status"] == "OK" for check in checks)
    return {
        "schema_version": 1,
        "type": "guard_pack_audit",
        "pack": pack["id"],
        "target": target_id,
        "home": str(home),
        "status": "READY" if ready else "INCOMPLETE",
        "checks": checks,
    }


def cmd_validate_packs(args: argparse.Namespace) -> int:
    errors: list[str] = []
    paths = discover_pack_paths(Path(args.packs_dir))
    if not paths:
        errors.append(f"no guard packs found under {args.packs_dir}")
    for path in paths:
        try:
            data = load_pack_data(path)
            errors.extend(f"{path}: {error}" for error in validate_pack(data, path))
        except PackError as exc:
            errors.append(str(exc))
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print("OK: guard pack manifests validate")
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    rows: list[tuple[str, str, str]] = []
    for path, data in iter_packs(Path(args.packs_dir)):
        errors = validate_pack(data, path)
        if errors:
            raise PackError("\n".join(f"{path}: {error}" for error in errors))
        rows.append((str(data["id"]), str(data["status"]), str(data["summary"])))
    if not rows:
        raise PackError(f"no guard packs found under {args.packs_dir}")
    for pack_id, status, summary in rows:
        print(f"{pack_id}\t{status}\t{summary}")
    return 0


def print_list(title: str, items: list[str], *, indent: str = "") -> None:
    if not items:
        return
    print(f"{indent}{title}:")
    for item in items:
        print(f"{indent}  - {item}")


def cmd_explain(args: argparse.Namespace) -> int:
    _, pack = load_pack(args.pack, Path(args.packs_dir))
    print(f"{pack['display_name']} ({pack['id']})")
    print(f"Status: {pack['status']}")
    print(f"Version: {pack['version']}")
    print(f"Summary: {pack['summary']}")
    print(f"Boundary: {pack['adoption_layer_statement']}")
    print()
    print("Source of truth:")
    for group, paths in sorted(pack["source_of_truth"].items()):
        print(f"  {group}:")
        for path in paths:
            print(f"    - {path}")
    print()
    print("Targets:")
    for target_id, target in sorted(pack["targets"].items()):
        print(f"  - {target_id}: {target['support']}")
        print_list("Surfaces", target.get("surfaces", []), indent="    ")
        print_list("Would install", target.get("would_install", []), indent="    ")
        print_list("Would modify", target.get("would_modify", []), indent="    ")
        print_list("Limitations", target.get("limitations", []), indent="    ")
    print()
    print(f"Default profile: {pack['profiles']['default']}")
    print(f"Allowed profiles: {', '.join(pack['profiles']['allowed'])}")
    return 0


def cmd_install(args: argparse.Namespace) -> int:
    _, pack = load_pack(args.pack, Path(args.packs_dir))
    target = target_for_pack(pack, args.target)
    validate_install_target(pack, args.target, target)
    validate_profile(pack, args.profile)
    receipt = build_receipt(pack, args.target, args.profile, target)

    if args.dry_run:
        print(f"DRY-RUN: install guard pack {pack['id']} for {args.target}")
        print(f"Profile: {args.profile}")
        print(f"Boundary: {pack['adoption_layer_statement']}")
        print_list("Would install", target.get("would_install", []))
        print_list("Would modify", target.get("would_modify", []))
        print_list("Would enable surfaces", target.get("surfaces", []))
        print_list("Limitations", target.get("limitations", []))
        print(
            f"Receipt preview: guard_pack={pack['id']} target={args.target} "
            f"profile={args.profile} writes=0"
        )
        print(f"Receipt path: {receipt['receipt_path']}")
        print_list("Rollback plan", receipt["rollback_plan"])
        print(f"Audit command: {receipt['audit']['command']}")
        return 0

    home = Path(args.home).expanduser()
    audit = build_audit(pack, args.target, home)
    if audit["status"] != "READY":
        print(
            f"ERROR: guard pack {pack['id']} audit is INCOMPLETE for {args.target}; "
            "receipt was not written.",
            file=sys.stderr,
        )
        for check in audit["checks"]:
            if check["status"] != "OK":
                print(f"  {check['status']} {check['id']}: {check['detail']}", file=sys.stderr)
        print(f"Run: bash setup.sh packs audit {pack['id']} --target {args.target}", file=sys.stderr)
        print("Use the full setup installer to create missing Core hook/runtime files.", file=sys.stderr)
        return 1

    receipt = build_receipt(pack, args.target, args.profile, target, dry_run=False, audit=audit)
    receipt_file = receipt_file_for_pack(str(pack["id"]), args.target, home)
    write_install_receipt(receipt_file, receipt)
    print(f"INSTALLED: guard pack {pack['id']} registered for {args.target}")
    print(f"Receipt: {receipt['receipt_path']}")
    print("Writes: 1")
    print("No hook/config files were modified by this command.")
    return 0


def cmd_receipt(args: argparse.Namespace) -> int:
    _, pack = load_pack(args.pack, Path(args.packs_dir))
    target = target_for_pack(pack, args.target)
    validate_install_target(pack, args.target, target)
    validate_profile(pack, args.profile)
    receipt = build_receipt(pack, args.target, args.profile, target)
    print(json.dumps(receipt, indent=2, sort_keys=True))
    return 0


def cmd_audit(args: argparse.Namespace) -> int:
    _, pack = load_pack(args.pack, Path(args.packs_dir))
    audit = build_audit(pack, args.target, Path(args.home).expanduser())
    if args.json:
        print(json.dumps(audit, indent=2, sort_keys=True))
    else:
        print(f"Audit: {audit['pack']} for {audit['target']}")
        print(f"Home: {audit['home']}")
        print(f"Status: {audit['status']}")
        for check in audit["checks"]:
            print(f"  {check['status']} {check['id']}: {check['detail']} ({check['path']})")
    return 0 if audit["status"] == "READY" else 1


def cmd_uninstall(args: argparse.Namespace) -> int:
    _, pack = load_pack(args.pack, Path(args.packs_dir))
    target = target_for_pack(pack, args.target)
    validate_install_target(pack, args.target, target)
    home = Path(args.home).expanduser()
    receipt_file = receipt_file_for_pack(str(pack["id"]), args.target, home)
    assert_receipt_path_safe(receipt_file, home)
    receipt = load_install_receipt(receipt_file)
    validate_install_receipt(receipt, pack, args.target)
    if args.dry_run:
        print(f"DRY-RUN: uninstall guard pack {pack['id']} for {args.target}")
        print(f"Would remove: {receipt_path_for_pack(str(pack['id']), args.target)}")
        print("Writes: 0")
        return 0
    remove_install_receipt(receipt_file)
    try:
        receipt_file.parent.rmdir()
    except OSError:
        print(f"Kept non-empty directory: {display_home_path(receipt_file.parent, home)}")
    print(f"UNINSTALLED: guard pack {pack['id']} receipt removed for {args.target}")
    print(f"Removed: {receipt_path_for_pack(str(pack['id']), args.target)}")
    print("No hook/config files were modified by this command.")
    return 0


def cmd_demo(args: argparse.Namespace) -> int:
    _, pack = load_pack(args.pack, Path(args.packs_dir))
    demo = pack["demo"]
    print(f"VibeGuard demo: {pack['id']}")
    print("No command is executed; this is a deterministic demo transcript.")
    print(f"Blocked example: {demo['blocked_example']}")
    print(f"Expected decision: {demo['expected_decision']}")
    print(f"Expected reason contains: {demo['expected_reason_contains']}")
    print(f"Run after install: {demo['command']}")
    return 0


def build_guard_pack_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="VibeGuard Guard Pack helper")
    parser.add_argument("--packs-dir", default=str(PACKS_DIR))
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("validate", help="Validate all Guard Pack manifests")
    sub.add_parser("list", help="List available Guard Packs")

    explain = sub.add_parser("explain", help="Explain one Guard Pack")
    explain.add_argument("pack")

    install = sub.add_parser("install", help="Install a Guard Pack")
    install.add_argument("--target", required=True, choices=sorted(SUPPORTED_TARGETS))
    install.add_argument("--pack", required=True)
    install.add_argument("--profile", default="core")
    install.add_argument("--home", default=str(Path.home()))
    install.add_argument("--dry-run", action="store_true")

    uninstall = sub.add_parser("uninstall", help="Uninstall a Guard Pack receipt")
    uninstall.add_argument("pack")
    uninstall.add_argument("--target", required=True, choices=sorted(SUPPORTED_TARGETS))
    uninstall.add_argument("--home", default=str(Path.home()))
    uninstall.add_argument("--dry-run", action="store_true")

    receipt = sub.add_parser("receipt", help="Print a deterministic dry-run receipt")
    receipt.add_argument("pack")
    receipt.add_argument("--target", required=True, choices=sorted(SUPPORTED_TARGETS))
    receipt.add_argument("--profile", default="core")

    audit = sub.add_parser("audit", help="Audit local state for a Guard Pack target")
    audit.add_argument("pack")
    audit.add_argument("--target", required=True, choices=sorted(SUPPORTED_TARGETS))
    audit.add_argument("--home", default=str(Path.home()))
    audit.add_argument("--json", action="store_true")

    demo = sub.add_parser("demo", help="Show a no-side-effect Guard Pack demo")
    demo.add_argument("pack")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_guard_pack_parser()
    args = parser.parse_args(argv)
    try:
        if args.command == "validate":
            return cmd_validate_packs(args)
        if args.command == "list":
            return cmd_list(args)
        if args.command == "explain":
            return cmd_explain(args)
        if args.command == "install":
            return cmd_install(args)
        if args.command == "uninstall":
            return cmd_uninstall(args)
        if args.command == "receipt":
            return cmd_receipt(args)
        if args.command == "audit":
            return cmd_audit(args)
        if args.command == "demo":
            return cmd_demo(args)
    except (PackError, ReceiptError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    parser.error("unknown command")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Shared repo-local OMX state helpers.

This module is the single source of truth for:
- resolving the active OMX scope
- validating lifecycle + verification payloads
- atomically writing `.omx/state/<scope>/completion.json`
- appending `.omx/state/<scope>/verification-log.jsonl`
- reading the canonical current-plan pointer
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


VALID_COMPLETION_STATUSES = {
    "active",
    "in_progress",
    "incomplete",
    "completed",
    "failed",
    "cancelled",
}
VALID_VERIFICATION_STATUSES = {"missing", "pass", "fail", "warn", "stale", "unknown"}


class StateError(RuntimeError):
    """Raised when OMX state is malformed or invalid."""


def _utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _ensure_str(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value:
        raise StateError(f"{field} must be a non-empty string")
    return value


def _ensure_optional_str(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise StateError(f"{field} must be a string or null")
    return value


def _ensure_string_list(value: Any, field: str) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        raise StateError(f"{field} must be a list of strings")
    return value


def _slugify(raw: str) -> str:
    cleaned = []
    for char in raw:
        if char.isalnum():
            cleaned.append(char.lower())
        else:
            cleaned.append("-")
    slug = "".join(cleaned).strip("-")
    while "--" in slug:
        slug = slug.replace("--", "-")
    return slug or "scope"


def _scoped_name(prefix: str, raw: str) -> str:
    slug = _slugify(raw)
    digest = hashlib.sha256(raw.encode("utf-8")).hexdigest()[:12]
    return f"{prefix}-{slug}-{digest}"


def _repo_root_from_env() -> Path | None:
    raw = os.environ.get("VIBEGUARD_REPO_ROOT")
    if raw:
        path = Path(raw).expanduser().resolve()
        return path
    return None


def repo_root_from_cwd(cwd: str | os.PathLike[str] | None = None) -> Path:
    repo_from_env = _repo_root_from_env()
    if repo_from_env is not None:
        return repo_from_env

    cwd_path = Path(cwd).resolve() if cwd else Path.cwd()
    try:
        proc = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            cwd=str(cwd_path),
            text=True,
            capture_output=True,
            check=True,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        raise StateError(f"unable to resolve git repo root from {cwd_path}: {exc}") from exc
    return Path(proc.stdout.strip()).resolve()


def _read_json_file(path: Path, *, allow_missing: bool = True) -> dict[str, Any] | None:
    if not path.exists():
        if allow_missing:
            return None
        raise StateError(f"{path} does not exist")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise StateError(f"invalid JSON in {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise StateError(f"{path} must contain a JSON object")
    return data


def _atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    serialized = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    with tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=str(path.parent),
        prefix=f".{path.name}.tmp.",
        delete=False,
    ) as handle:
        handle.write(serialized)
        temp_path = Path(handle.name)
    temp_path.replace(path)


def _append_jsonl(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, ensure_ascii=False, sort_keys=True) + "\n")


@dataclass(frozen=True)
class ScopeInfo:
    repo_root: Path
    scope: str
    scope_source: str
    mode: str
    current_step: str | None
    current_plan_path: str | None
    pointer_error: str | None

    @property
    def state_root(self) -> Path:
        return self.repo_root / ".omx" / "state"

    @property
    def scope_dir(self) -> Path:
        return self.state_root / self.scope

    @property
    def completion_path(self) -> Path:
        return self.scope_dir / "completion.json"

    @property
    def verification_log_path(self) -> Path:
        return self.scope_dir / "verification-log.jsonl"

    @property
    def current_plan_pointer_path(self) -> Path:
        return self.state_root / "current-plan.json"

    def to_dict(self) -> dict[str, Any]:
        return {
            "repo_root": str(self.repo_root),
            "scope": self.scope,
            "scope_source": self.scope_source,
            "mode": self.mode,
            "current_step": self.current_step,
            "current_plan_path": self.current_plan_path,
            "pointer_error": self.pointer_error,
            "state_dir": _relative_to_repo(self.scope_dir, self.repo_root),
            "completion_path": _relative_to_repo(self.completion_path, self.repo_root),
            "verification_log_path": _relative_to_repo(self.verification_log_path, self.repo_root),
            "current_plan_pointer_path": _relative_to_repo(self.current_plan_pointer_path, self.repo_root),
        }


def _relative_to_repo(path: Path, repo_root: Path) -> str:
    try:
        return str(path.relative_to(repo_root))
    except ValueError:
        return str(path)


def _validate_current_plan_pointer(data: dict[str, Any]) -> dict[str, Any]:
    scope = _ensure_str(data.get("scope"), "scope")
    plan_path = _ensure_str(data.get("plan_path"), "plan_path")
    updated_at = _ensure_str(data.get("updated_at"), "updated_at")
    mode = data.get("mode")
    if mode is not None and not isinstance(mode, str):
        raise StateError("mode must be a string or null")
    current_step = data.get("current_step")
    if current_step is not None and not isinstance(current_step, str):
        raise StateError("current_step must be a string or null")
    next_required_action = data.get("next_required_action")
    if next_required_action is not None and not isinstance(next_required_action, str):
        raise StateError("next_required_action must be a string or null")
    return {
        "scope": scope,
        "plan_path": plan_path,
        "updated_at": updated_at,
        "mode": mode,
        "current_step": current_step,
        "next_required_action": next_required_action,
    }


def load_current_plan_pointer(repo_root: Path) -> tuple[dict[str, Any] | None, str | None]:
    path = repo_root / ".omx" / "state" / "current-plan.json"
    if not path.exists():
        return None, None
    try:
        data = _read_json_file(path, allow_missing=False)
        assert data is not None
        return _validate_current_plan_pointer(data), None
    except StateError as exc:
        return None, str(exc)


def write_current_plan_pointer(repo_root: Path, payload: dict[str, Any]) -> dict[str, Any]:
    pointer = _validate_current_plan_pointer(payload)
    path = repo_root / ".omx" / "state" / "current-plan.json"
    _atomic_write_json(path, pointer)
    return pointer


def resolve_scope(
    repo_root: Path,
    *,
    explicit_scope: str | None = None,
    thread_id: str | None = None,
    session_id: str | None = None,
    mode: str | None = None,
) -> ScopeInfo:
    pointer, pointer_error = load_current_plan_pointer(repo_root)
    resolved_mode = mode or os.environ.get("VIBEGUARD_MODE") or (pointer or {}).get("mode") or os.environ.get("VIBEGUARD_CLI") or "unknown"
    if explicit_scope:
        scope = _slugify(explicit_scope)
        source = "explicit"
    elif pointer and isinstance(pointer.get("scope"), str) and pointer["scope"]:
        scope = _slugify(pointer["scope"])
        source = "current-plan"
    elif thread_id:
        scope = _scoped_name("thread", thread_id)
        source = "thread"
    elif session_id:
        scope = _scoped_name("session", session_id)
        source = "session"
    else:
        scope = _scoped_name("repo", str(repo_root))
        source = "repo"
    return ScopeInfo(
        repo_root=repo_root,
        scope=scope,
        scope_source=source,
        mode=resolved_mode,
        current_step=(pointer or {}).get("current_step"),
        current_plan_path=(pointer or {}).get("plan_path"),
        pointer_error=pointer_error,
    )


def _artifacts_for(scope_info: ScopeInfo) -> dict[str, str]:
    return {
        "completion": _relative_to_repo(scope_info.completion_path, scope_info.repo_root),
        "verification_log": _relative_to_repo(scope_info.verification_log_path, scope_info.repo_root),
        "current_plan": _relative_to_repo(scope_info.current_plan_pointer_path, scope_info.repo_root),
    }


def _validate_completion(scope_info: ScopeInfo, data: dict[str, Any]) -> dict[str, Any]:
    status = _ensure_str(data.get("status"), "status")
    if status not in VALID_COMPLETION_STATUSES:
        raise StateError(f"status must be one of {sorted(VALID_COMPLETION_STATUSES)}")

    verification_status = _ensure_str(data.get("verification_status"), "verification_status")
    if verification_status not in VALID_VERIFICATION_STATUSES:
        raise StateError(f"verification_status must be one of {sorted(VALID_VERIFICATION_STATUSES)}")

    scope = _ensure_str(data.get("scope"), "scope")
    if scope != scope_info.scope:
        raise StateError(f"scope mismatch: expected {scope_info.scope}, got {scope}")

    mode = _ensure_str(data.get("mode"), "mode")
    started_at = _ensure_str(data.get("started_at"), "started_at")
    updated_at = _ensure_str(data.get("updated_at"), "updated_at")

    completed_at = _ensure_optional_str(data.get("completed_at"), "completed_at")
    cancelled_at = _ensure_optional_str(data.get("cancelled_at"), "cancelled_at")
    current_step = _ensure_optional_str(data.get("current_step"), "current_step")
    next_required_action = _ensure_optional_str(data.get("next_required_action"), "next_required_action")
    verification_entry_id = _ensure_optional_str(data.get("verification_entry_id"), "verification_entry_id")
    verification_commands = _ensure_string_list(data.get("verification_commands"), "verification_commands")
    known_failures = _ensure_string_list(data.get("known_failures"), "known_failures")
    artifacts = data.get("artifacts")
    if artifacts is not None:
        if not isinstance(artifacts, dict):
            raise StateError("artifacts must be an object")
        for key, expected in _artifacts_for(scope_info).items():
            if artifacts.get(key) != expected:
                raise StateError(f"artifacts.{key} must equal {expected}")

    return {
        "mode": mode,
        "scope": scope,
        "status": status,
        "started_at": started_at,
        "updated_at": updated_at,
        "completed_at": completed_at,
        "cancelled_at": cancelled_at,
        "current_step": current_step,
        "verification_status": verification_status,
        "verification_entry_id": verification_entry_id,
        "verification_commands": verification_commands,
        "known_failures": known_failures,
        "next_required_action": next_required_action,
        "artifacts": _artifacts_for(scope_info),
    }


def read_completion(scope_info: ScopeInfo) -> dict[str, Any] | None:
    data = _read_json_file(scope_info.completion_path, allow_missing=True)
    if data is None:
        return None
    return _validate_completion(scope_info, data)


def write_completion(scope_info: ScopeInfo, payload: dict[str, Any]) -> dict[str, Any]:
    existing: dict[str, Any] | None = None
    existing_error: str | None = None
    try:
        existing = read_completion(scope_info)
    except StateError as exc:
        existing_error = str(exc)

    now = _utc_now()
    status = _ensure_str(payload.get("status"), "status")
    if status not in VALID_COMPLETION_STATUSES:
        raise StateError(f"status must be one of {sorted(VALID_COMPLETION_STATUSES)}")

    verification_status = payload.get("verification_status", "unknown")
    if verification_status not in VALID_VERIFICATION_STATUSES:
        raise StateError(f"verification_status must be one of {sorted(VALID_VERIFICATION_STATUSES)}")

    if status == "completed" and verification_status != "pass":
        raise StateError("completed status requires verification_status=pass")

    completion = {
        "mode": _ensure_str(payload.get("mode") or scope_info.mode, "mode"),
        "scope": scope_info.scope,
        "status": status,
        "started_at": (existing or {}).get("started_at") or payload.get("started_at") or now,
        "updated_at": now,
        "completed_at": now if status == "completed" else None,
        "cancelled_at": now if status == "cancelled" else None,
        "current_step": payload.get("current_step", scope_info.current_step),
        "verification_status": verification_status,
        "verification_entry_id": payload.get("verification_entry_id"),
        "verification_commands": _ensure_string_list(payload.get("verification_commands"), "verification_commands"),
        "known_failures": _ensure_string_list(payload.get("known_failures"), "known_failures"),
        "next_required_action": payload.get("next_required_action"),
        "artifacts": _artifacts_for(scope_info),
    }
    if existing_error is not None:
        completion["known_failures"] = completion["known_failures"] + [f"prior-state-error: {existing_error}"]
        completion["next_required_action"] = (
            "Repair malformed OMX state and rerun verification before claiming completion."
        )
        if status == "completed":
            raise StateError("cannot mark completion completed while prior completion state is malformed")

    validated = _validate_completion(scope_info, completion)
    _atomic_write_json(scope_info.completion_path, validated)
    return validated


def _validate_verification_row(scope_info: ScopeInfo, data: dict[str, Any]) -> dict[str, Any]:
    status = _ensure_str(data.get("status"), "status")
    if status not in VALID_VERIFICATION_STATUSES:
        raise StateError(f"status must be one of {sorted(VALID_VERIFICATION_STATUSES)}")
    scope = _ensure_str(data.get("scope"), "scope")
    if scope != scope_info.scope:
        raise StateError(f"scope mismatch: expected {scope_info.scope}, got {scope}")
    source = _ensure_str(data.get("source"), "source")
    ts = _ensure_str(data.get("ts"), "ts")
    entry_id = _ensure_str(data.get("entry_id"), "entry_id")
    summary = _ensure_optional_str(data.get("summary"), "summary")
    turn_id = _ensure_optional_str(data.get("turn_id"), "turn_id")
    session_id = _ensure_optional_str(data.get("session_id"), "session_id")
    commands = _ensure_string_list(data.get("commands"), "commands")
    known_failures = _ensure_string_list(data.get("known_failures"), "known_failures")
    return {
        "entry_id": entry_id,
        "ts": ts,
        "scope": scope,
        "status": status,
        "source": source,
        "summary": summary,
        "turn_id": turn_id,
        "session_id": session_id,
        "commands": commands,
        "known_failures": known_failures,
    }


def _verification_entry_id(scope: str, turn_id: str | None, commands: list[str], source: str, status: str) -> str:
    seed = json.dumps(
        {"scope": scope, "turn_id": turn_id or "", "commands": commands, "source": source, "status": status},
        ensure_ascii=False,
        sort_keys=True,
    )
    return hashlib.sha256(seed.encode("utf-8")).hexdigest()[:16]


def append_verification(scope_info: ScopeInfo, payload: dict[str, Any]) -> dict[str, Any]:
    commands = _ensure_string_list(payload.get("commands"), "commands")
    status = _ensure_str(payload.get("status"), "status")
    if status not in VALID_VERIFICATION_STATUSES:
        raise StateError(f"status must be one of {sorted(VALID_VERIFICATION_STATUSES)}")
    source = _ensure_str(payload.get("source"), "source")
    turn_id = _ensure_optional_str(payload.get("turn_id"), "turn_id")
    session_id = _ensure_optional_str(payload.get("session_id"), "session_id")
    summary = _ensure_optional_str(payload.get("summary"), "summary")
    known_failures = _ensure_string_list(payload.get("known_failures"), "known_failures")
    row = {
        "entry_id": payload.get("entry_id") or _verification_entry_id(scope_info.scope, turn_id, commands, source, status),
        "ts": payload.get("ts") or _utc_now(),
        "scope": scope_info.scope,
        "status": status,
        "source": source,
        "summary": summary,
        "turn_id": turn_id,
        "session_id": session_id,
        "commands": commands,
        "known_failures": known_failures,
    }
    validated = _validate_verification_row(scope_info, row)
    _append_jsonl(scope_info.verification_log_path, validated)
    return validated


def latest_verification(scope_info: ScopeInfo) -> dict[str, Any] | None:
    path = scope_info.verification_log_path
    if not path.exists():
        return None
    latest: dict[str, Any] | None = None
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line:
                continue
            try:
                data = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(data, dict):
                continue
            try:
                validated = _validate_verification_row(scope_info, data)
            except StateError:
                continue
            latest = validated
    return latest


def scope_info_from_env(cwd: str | None = None) -> ScopeInfo:
    repo_root = repo_root_from_cwd(cwd)
    return resolve_scope(
        repo_root,
        explicit_scope=os.environ.get("VIBEGUARD_SCOPE"),
        thread_id=os.environ.get("VIBEGUARD_THREAD_ID"),
        session_id=os.environ.get("VIBEGUARD_SESSION_ID"),
        mode=os.environ.get("VIBEGUARD_MODE"),
    )


def _load_stdin_json() -> dict[str, Any]:
    raw = sys.stdin.read()
    if not raw.strip():
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise StateError(f"stdin payload must be JSON object: {exc}") from exc
    if not isinstance(data, dict):
        raise StateError("stdin payload must be a JSON object")
    return data


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="OMX repo-local state helpers")
    parser.add_argument(
        "--cwd",
        default=None,
        help="Working directory used to resolve the git repository root",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("scope-meta")
    subparsers.add_parser("read-completion")
    subparsers.add_parser("write-completion")
    subparsers.add_parser("latest-verification")
    subparsers.add_parser("append-verification")
    subparsers.add_parser("read-current-plan")
    subparsers.add_parser("write-current-plan")
    return parser


def _emit(obj: dict[str, Any]) -> int:
    print(json.dumps(obj, ensure_ascii=False, sort_keys=True))
    return 0


def main() -> int:
    parser = _build_parser()
    args = parser.parse_args()

    try:
        if args.command in {"read-current-plan", "write-current-plan"}:
            repo_root = repo_root_from_cwd(args.cwd)
            if args.command == "read-current-plan":
                pointer, error = load_current_plan_pointer(repo_root)
                return _emit({"pointer": pointer, "error": error})
            pointer = write_current_plan_pointer(repo_root, _load_stdin_json())
            return _emit({"pointer": pointer})

        scope_info = scope_info_from_env(args.cwd)
        if args.command == "scope-meta":
            return _emit(scope_info.to_dict())
        if args.command == "read-completion":
            return _emit({"completion": read_completion(scope_info), "scope": scope_info.to_dict()})
        if args.command == "write-completion":
            completion = write_completion(scope_info, _load_stdin_json())
            return _emit({"completion": completion, "scope": scope_info.to_dict()})
        if args.command == "latest-verification":
            return _emit({"verification": latest_verification(scope_info), "scope": scope_info.to_dict()})
        if args.command == "append-verification":
            row = append_verification(scope_info, _load_stdin_json())
            return _emit({"verification": row, "scope": scope_info.to_dict()})
    except StateError as exc:
        return _emit({"error": str(exc)})

    return 1


if __name__ == "__main__":
    raise SystemExit(main())

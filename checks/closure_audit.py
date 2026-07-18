#!/usr/bin/env python3
"""Audit post-dispatch merge ordering without writing to GitHub."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from specrail_lib import SpecRailError, resolve_repo_path, validate_instance


REPOSITORY_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
HEAD_RE = re.compile(r"^[0-9a-fA-F]{40}$")
MERGE_PATHS = {"gh_pr_merge", "api_fallback", "merged_by_other"}
TOP_LEVEL_FIELDS = {"repository", "pr_number", "final_head_sha", "gate", "merge"}
GATE_FIELDS = {
    "decision",
    "head_sha",
    "gate_query_completed_at",
    "gate_query_head_sha",
}
MERGE_FIELDS = {
    "merge_path",
    "remote_confirmed",
    "merge_dispatched_at",
    "merge_head_sha",
    "merged_at",
    "merged_head_sha",
}
GATE_FIELD_TYPES = {field: str for field in GATE_FIELDS}
MERGE_FIELD_TYPES = {
    "merge_path": str,
    "remote_confirmed": bool,
    "merge_dispatched_at": str,
    "merge_head_sha": str,
    "merged_at": str,
    "merged_head_sha": str,
}
VIOLATION_PRIORITY = [
    "external_merge_missing_chain",
    "closure_missing_gate_evidence",
    "closure_missing_dispatch_evidence",
    "closure_missing_merge_evidence",
    "closure_gate_not_allowed",
    "closure_head_mismatch",
    "closure_invalid_timestamp",
    "closure_dispatch_not_after_gate",
    "closure_merge_before_dispatch",
]
VIOLATION_SUMMARIES = {
    "external_merge_missing_chain": "External merge lacks the complete same-head gate and dispatch chain.",
    "closure_missing_gate_evidence": "Allowed gate evidence is missing or incomplete.",
    "closure_missing_dispatch_evidence": "Merge dispatch evidence is missing or incomplete.",
    "closure_missing_merge_evidence": "Remote merge evidence is missing or incomplete.",
    "closure_gate_not_allowed": "The recorded pre-merge gate decision is not allowed.",
    "closure_head_mismatch": "Gate, dispatch, merge, and final head evidence do not match.",
    "closure_invalid_timestamp": "Closure evidence contains a non-timezone-aware or invalid timestamp.",
    "closure_dispatch_not_after_gate": "Merge dispatch did not occur strictly after the gate query completed.",
    "closure_merge_before_dispatch": "The merge completed before its recorded dispatch time.",
}


class ClosureAuditError(ValueError):
    """Raised when closure audit input is malformed rather than incomplete."""


def _nonempty(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _positive_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def _unsupported_fields(value: dict[str, Any], allowed: set[str], label: str) -> None:
    unknown = sorted(set(value) - allowed)
    if unknown:
        raise ClosureAuditError(
            f"{label} contains unsupported fields: {', '.join(unknown)}"
        )


def _optional_object(value: Any, label: str) -> dict[str, Any] | None:
    if value is None:
        return None
    if not isinstance(value, dict):
        raise ClosureAuditError(f"{label} must be an object or null")
    return value


def _validate_optional_field_types(
    value: dict[str, Any],
    field_types: dict[str, type],
    label: str,
) -> None:
    for field, expected_type in field_types.items():
        item = value.get(field)
        if item is None or isinstance(item, expected_type):
            continue
        expected_name = "boolean" if expected_type is bool else "string"
        raise ClosureAuditError(
            f"{label}.{field} must be a {expected_name} or null"
        )


def _parse_timestamp(value: Any) -> datetime | None:
    if not _nonempty(value):
        return None
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo is not None else None


def _normalized_checked_at(value: str | None) -> str:
    if value is None:
        return (
            datetime.now(timezone.utc)
            .replace(microsecond=0)
            .isoformat()
            .replace("+00:00", "Z")
        )
    if _parse_timestamp(value) is None:
        raise ClosureAuditError("checked_at must be a timezone-aware ISO-8601 timestamp")
    return value.strip()


def _required_follow_up(
    code: str,
    repository: str,
    pr_number: int,
    final_head_sha: str,
) -> dict[str, Any]:
    identity = "\0".join(
        ["specrail-closure-v1", code, repository, str(pr_number), final_head_sha]
    )
    digest = hashlib.sha256(identity.encode("utf-8")).hexdigest()
    return {
        "violation_code": code,
        "repository": repository,
        "pr_number": pr_number,
        "final_head_sha": final_head_sha,
        "idempotency_key": f"specrail-closure-v1:{digest}",
        "summary": VIOLATION_SUMMARIES[code],
    }


def _complete(value: dict[str, Any] | None, fields: tuple[str, ...]) -> bool:
    return value is not None and all(_nonempty(value.get(field)) for field in fields)


def audit_closure(
    evidence: dict[str, Any],
    *,
    checked_at: str | None = None,
) -> dict[str, Any]:
    """Return a schema-shaped advisory compliance result for one merged PR."""

    if not isinstance(evidence, dict):
        raise ClosureAuditError("closure evidence must be an object")
    _unsupported_fields(evidence, TOP_LEVEL_FIELDS, "closure evidence")

    repository = evidence.get("repository")
    if not _nonempty(repository) or not REPOSITORY_RE.fullmatch(str(repository)):
        raise ClosureAuditError("repository must use OWNER/REPO format")
    repository = str(repository).strip().lower()
    pr_number = evidence.get("pr_number")
    if not _positive_int(pr_number):
        raise ClosureAuditError("pr_number must be a positive integer")
    final_head_sha = evidence.get("final_head_sha")
    if not _nonempty(final_head_sha) or not HEAD_RE.fullmatch(str(final_head_sha)):
        raise ClosureAuditError("final_head_sha must be a 40-character hexadecimal SHA")
    final_head_sha = str(final_head_sha).lower()

    gate = _optional_object(evidence.get("gate"), "gate")
    merge = _optional_object(evidence.get("merge"), "merge")
    if gate is not None:
        _unsupported_fields(gate, GATE_FIELDS, "gate")
        _validate_optional_field_types(gate, GATE_FIELD_TYPES, "gate")
    if merge is not None:
        _unsupported_fields(merge, MERGE_FIELDS, "merge")
        _validate_optional_field_types(merge, MERGE_FIELD_TYPES, "merge")
        merge_path = merge.get("merge_path")
        if merge_path is not None and (
            not isinstance(merge_path, str) or merge_path not in MERGE_PATHS
        ):
            raise ClosureAuditError(
                "merge.merge_path must be one of: " + ", ".join(sorted(MERGE_PATHS))
            )

    violations: set[str] = set()
    gate_complete = _complete(
        gate,
        ("decision", "head_sha", "gate_query_completed_at", "gate_query_head_sha"),
    )
    dispatch_complete = _complete(
        merge, ("merge_dispatched_at", "merge_head_sha")
    )
    merge_complete = _complete(
        merge, ("merge_path", "merged_at", "merged_head_sha")
    ) and merge is not None and merge.get("remote_confirmed") is True

    external_missing = (
        merge is not None
        and merge.get("merge_path") == "merged_by_other"
        and (not gate_complete or not dispatch_complete or not merge_complete)
    )
    if external_missing:
        violations.add("external_merge_missing_chain")
    if not gate_complete:
        violations.add("closure_missing_gate_evidence")
    if not dispatch_complete:
        violations.add("closure_missing_dispatch_evidence")
    if not merge_complete:
        violations.add("closure_missing_merge_evidence")

    if gate is not None and gate.get("decision") != "allowed":
        violations.add("closure_gate_not_allowed")

    head_values = [
        gate.get("head_sha") if gate else None,
        gate.get("gate_query_head_sha") if gate else None,
        merge.get("merge_head_sha") if merge else None,
        merge.get("merged_head_sha") if merge else None,
    ]
    if any(_nonempty(value) and str(value).lower() != final_head_sha for value in head_values):
        violations.add("closure_head_mismatch")

    gate_time = _parse_timestamp(gate.get("gate_query_completed_at") if gate else None)
    dispatch_time = _parse_timestamp(merge.get("merge_dispatched_at") if merge else None)
    merged_time = _parse_timestamp(merge.get("merged_at") if merge else None)
    timestamp_inputs = [
        gate.get("gate_query_completed_at") if gate else None,
        merge.get("merge_dispatched_at") if merge else None,
        merge.get("merged_at") if merge else None,
    ]
    if any(_nonempty(raw) and parsed is None for raw, parsed in zip(timestamp_inputs, [gate_time, dispatch_time, merged_time])):
        violations.add("closure_invalid_timestamp")
    if gate_time is not None and dispatch_time is not None and gate_time >= dispatch_time:
        violations.add("closure_dispatch_not_after_gate")
    if dispatch_time is not None and merged_time is not None and dispatch_time > merged_time:
        violations.add("closure_merge_before_dispatch")

    ordered = [code for code in VIOLATION_PRIORITY if code in violations]
    violation_items = [
        {"code": code, "summary": VIOLATION_SUMMARIES[code]} for code in ordered
    ]
    result: dict[str, Any] = {
        "version": 1,
        "status": "violation" if ordered else "compliant",
        "advisory_only": True,
        "github_writes_performed": False,
        "repository": repository,
        "pr_number": pr_number,
        "final_head_sha": final_head_sha,
        "checked_at": _normalized_checked_at(checked_at),
        "violations": violation_items,
        "required_follow_up": None,
    }
    if ordered:
        result["required_follow_up"] = _required_follow_up(
            ordered[0], repository, pr_number, final_head_sha
        )
    return result


def _load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise ClosureAuditError(f"cannot read closure evidence {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ClosureAuditError(
            f"invalid closure evidence JSON {path}: {exc.msg}"
        ) from exc
    if not isinstance(value, dict):
        raise ClosureAuditError("closure evidence JSON must be an object")
    return value


def _load_schema(repo: Path) -> dict[str, Any]:
    path = resolve_repo_path(
        repo,
        "schemas/closure_audit_result.schema.json",
        label="closure audit schema",
    )
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise ClosureAuditError(f"cannot read closure audit schema {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ClosureAuditError(f"invalid closure audit schema {path}: {exc.msg}") from exc
    if not isinstance(value, dict):
        raise ClosureAuditError("closure audit schema must be an object")
    return value


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Audit post-dispatch merge ordering without GitHub writes."
    )
    parser.add_argument("--repo", default=".", help="Repository root")
    parser.add_argument("--evidence", required=True, help="Closure evidence JSON")
    parser.add_argument("--checked-at", help="Optional deterministic audit timestamp")
    parser.add_argument("--json", action="store_true", help="Print JSON output")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        repo = Path(args.repo).resolve()
        evidence_path = resolve_repo_path(
            repo,
            args.evidence,
            label="closure evidence",
        )
        result = audit_closure(
            _load_json(evidence_path), checked_at=args.checked_at
        )
        validate_instance(_load_schema(repo), result, "closure audit result")
    except (ClosureAuditError, SpecRailError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["status"] == "compliant" else 1


if __name__ == "__main__":
    raise SystemExit(main())

"""Validate only the schema and template assets owned by the SpecRail pack."""

from __future__ import annotations

import json
from pathlib import Path


SPEC_SCHEMA_FILES = frozenset(
    {
        "adoption_matrix.schema.json",
        "duplicate_work_evidence.schema.json",
        "evaluation_result.schema.json",
        "flow_manifest.schema.json",
        "issue_evidence.schema.json",
        "issue_triage.schema.json",
        "pr_review_gate.schema.json",
        "review_result.schema.json",
        "runtime_checkpoint.schema.json",
        "spec_packet.schema.json",
        "task_plan.schema.json",
        "workflow_run.schema.json",
    }
)
SPEC_TEMPLATE_FILES = frozenset(
    {
        "issue_bug.md",
        "issue_feature.md",
        "product_spec.md",
        "pull_request.md",
        "tasks.md",
        "tech_spec.md",
        "tranche_checkpoint.md",
    }
)
STABLE_TEMPLATE_FILES = frozenset(
    {"issue_feature.md", "product_spec.md", "pull_request.md", "tech_spec.md"}
)
STABLE_TEMPLATE_TOKENS = ("GH-", "ready_to_spec", "ready_to_implement")


def _read_asset_text(path: Path, repo: Path, errors: list[str]) -> str | None:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        relative_path = path.relative_to(repo)
        errors.append(f"{relative_path}: cannot read SpecRail asset: {exc}")
        return None


def validate_template_parity(repo: Path) -> list[str]:
    errors: list[str] = []
    template_root = repo / "templates"
    localized_root = template_root / "zh-CN"
    for name in sorted(SPEC_TEMPLATE_FILES):
        base_path = template_root / name
        localized_path = localized_root / name
        if not base_path.is_file():
            errors.append(f"templates: missing SpecRail template {name}")
            continue
        if not localized_path.is_file():
            errors.append(f"templates/zh-CN: missing localized template {name}")
            continue
        if name not in STABLE_TEMPLATE_FILES:
            continue
        base_text = _read_asset_text(base_path, repo, errors)
        localized_text = _read_asset_text(localized_path, repo, errors)
        if base_text is None or localized_text is None:
            continue
        for token in STABLE_TEMPLATE_TOKENS:
            if token in base_text and token not in localized_text:
                errors.append(f"templates/zh-CN/{name}: missing stable token {token}")
    return errors


def validate_json_schemas(repo: Path) -> list[str]:
    errors: list[str] = []
    schema_root = repo / "schemas"
    for name in sorted(SPEC_SCHEMA_FILES):
        path = schema_root / name
        if not path.is_file():
            errors.append(f"schemas: missing SpecRail schema {name}")
            continue
        raw_schema = _read_asset_text(path, repo, errors)
        if raw_schema is None:
            continue
        try:
            data = json.loads(raw_schema)
        except json.JSONDecodeError as exc:
            errors.append(f"schemas/{name}: invalid JSON: {exc}")
            continue
        if not isinstance(data, dict):
            errors.append(f"schemas/{name}: top-level JSON must be an object")
            continue
        if "$schema" not in data:
            errors.append(f"schemas/{name}: missing $schema")
        if "title" not in data:
            errors.append(f"schemas/{name}: missing title")
        if data.get("type") != "object":
            errors.append(f"schemas/{name}: top-level type must be object")
    return errors

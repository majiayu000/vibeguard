#!/usr/bin/env python3
"""Validate a SpecRail workflow pack without network or GitHub writes."""

from __future__ import annotations

import argparse
import importlib.util
import re
import sys
from pathlib import Path, PurePosixPath

from specrail_lib import (
    SpecRailError,
    artifact_templates,
    load_pack,
    read_text,
    resolve_path,
    resolve_repo_path,
    resolve_spec_packet_root,
    spec_packet_artifact_paths,
    validate_action_policy,
    validate_labels,
    validate_state_graph,
    validate_skills_lock,
)
from sensitive_enforcement import (
    parse_planned_changes_manifest,
    validate_sensitive_registry,
)


REQUIRED_FILES = [
    "README.md",
    "LICENSE",
    "CHANGELOG.md",
    "SPEC.md",
    "docs/ADOPTION_MATRIX.md",
    "workflow.yaml",
    "states.yaml",
    "labels.yaml",
    "examples/adoptions/matrix.json",
    "checks/duplicate_work_gate.py",
    "checks/github_evidence_common.py",
    "checks/github_duplicate_evidence.py",
    "checks/github_approved_spec_evidence.py",
    "checks/github_issue_reference.py",
    "checks/github_issue_evidence.py",
    "checks/github_pr_evidence.py",
    "checks/github_pr_snapshot.py",
    "checks/github_review_evidence.py",
    "checks/pack_asset_validation.py",
    "checks/closure_audit.py",
    "checks/pr_gate.py",
    "checks/pr_review_contract.py",
    "checks/review_json_gate.py",
    "checks/review_result_semantics.py",
    "schemas/duplicate_work_evidence.schema.json",
    "tools/install_codex_skills.py",
    "skills-lock.json",
    "templates/issue_bug.md",
    "templates/issue_feature.md",
    "templates/product_spec.md",
    "templates/tech_spec.md",
    "templates/tasks.md",
    "templates/pull_request.md",
    "templates/zh-CN/issue_bug.md",
    "templates/zh-CN/issue_feature.md",
    "templates/zh-CN/product_spec.md",
    "templates/zh-CN/tech_spec.md",
    "templates/zh-CN/tasks.md",
    "templates/zh-CN/pull_request.md",
    "templates/zh-CN/tranche_checkpoint.md",
    "review/agent_first_review.md",
    "review/human_final_review.md",
    "policies/security_disclosure.md",
    "policies/maintainer_escalation.md",
    "checks/runtime_ledger_gate.py",
    "checks/runtime_gate_rules.py",
    "checks/schema_validation.py",
    "checks/sensitive_enforcement.py",
    "templates/tranche_checkpoint.md",
]
REQUIRED_FILE_GLOBS = [
    "examples/fixtures/*",
    "schemas/*.schema.json",
]

PLANNED_CHANGES_REQUIRED_MARKER = "specrail-requires-planned-changes-v1"

VALID_AUTH_MODES = ("auto", "review")

REQUIRED_TOKENS = {
    "workflow.yaml": [
        "default_mode: dry_run",
        "auth_mode:",
        "auth_modes:",
        "forbidden_agent_actions:",
        "required_human_gates:",
        "action_policy:",
    ],
    "states.yaml": [
        "ready_to_spec",
        "ready_to_implement",
        "agent_review",
        "human_review",
        "merge_ready",
    ],
    "labels.yaml": [
        "readiness:",
        "ready_to_spec",
        "ready_to_implement",
        "security_private",
    ],
    "templates/product_spec.md": [
        "## Goals",
        "## Non-Goals",
        "## Acceptance Criteria",
    ],
    "templates/tech_spec.md": [
        "## Proposed Design",
        "## Test Plan",
        "## Rollback Plan",
        PLANNED_CHANGES_REQUIRED_MARKER,
    ],
    "templates/tasks.md": [
        "## Implementation Tasks",
        "## Verification",
        "## Handoff Notes",
    ],
    "templates/pull_request.md": [
        "## Linked Work",
        "## Readiness Gate",
        "## Review Gate",
        "## Merge Gate",
        "## Verification",
    ],
}


def validate_required_files(repo: Path) -> list[str]:
    errors: list[str] = []
    for rel in REQUIRED_FILES:
        path = repo / rel
        if not path.is_file():
            errors.append(f"missing required file: {rel}")
    return errors


def validate_required_file_globs(repo: Path) -> list[str]:
    errors: list[str] = []
    for pattern in REQUIRED_FILE_GLOBS:
        matches = sorted(path for path in repo.glob(pattern) if path.is_file())
        if not matches:
            errors.append(f"missing required files matching: {pattern}")
    return errors


def validate_tokens(repo: Path) -> list[str]:
    errors: list[str] = []
    for rel, tokens in REQUIRED_TOKENS.items():
        path = repo / rel
        if not path.is_file():
            continue
        text = read_text(path)
        for token in tokens:
            if token not in text:
                errors.append(f"{rel}: missing token {token!r}")
    return errors


def validate_pack_assets(repo: Path) -> list[str]:
    helper_path = Path(__file__).with_name("pack_asset_validation.py")
    if not helper_path.is_file():
        return [
            "cannot load trusted pack asset validation: "
            "checks/pack_asset_validation.py is missing"
        ]
    try:
        spec = importlib.util.spec_from_file_location(
            "_specrail_trusted_pack_asset_validation",
            helper_path,
        )
        if spec is None or spec.loader is None:
            return ["cannot load trusted pack asset validation: no module loader"]
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        validate_json_schemas = getattr(module, "validate_json_schemas", None)
        validate_template_parity = getattr(module, "validate_template_parity", None)
        if not callable(validate_json_schemas) or not callable(validate_template_parity):
            return [
                "trusted pack asset validation must define callable "
                "validate_json_schemas and validate_template_parity"
            ]
        return validate_json_schemas(repo) + validate_template_parity(repo)
    except Exception as exc:
        return [f"cannot run trusted pack asset validation: {exc}"]


def validate_impl_branch_template(config: object) -> list[str]:
    errors: list[str] = []
    try:
        artifacts = artifact_templates(config)  # type: ignore[arg-type]
    except SpecRailError as exc:
        return [str(exc)]
    template = artifacts.get("impl_branch")
    if not template:
        return ["workflow.yaml: artifacts.impl_branch is required"]
    if "{issue_number}" not in template:
        errors.append("workflow.yaml: artifacts.impl_branch must contain {issue_number}")
    return errors


def validate_auth_mode(config: object) -> list[str]:
    errors: list[str] = []
    workflow = config.workflow  # type: ignore[attr-defined]
    policy = workflow.get("automation_policy")
    if not isinstance(policy, dict):
        return ["workflow.yaml: automation_policy must be a mapping"]

    auth_mode = policy.get("auth_mode")
    if auth_mode not in VALID_AUTH_MODES:
        errors.append(
            "workflow.yaml: automation_policy.auth_mode must be one of: "
            + ", ".join(VALID_AUTH_MODES)
        )
    elif auth_mode != "review":
        errors.append(
            "workflow.yaml: automation_policy.auth_mode must be review; "
            "auto requires an explicit current implx auto invocation"
        )

    gates = workflow.get("required_human_gates")
    gate_names = {str(gate) for gate in gates} if isinstance(gates, list) else set()

    modes = workflow.get("auth_modes")
    if not isinstance(modes, dict):
        errors.append("workflow.yaml: auth_modes must be a mapping")
        return errors
    for mode in VALID_AUTH_MODES:
        body = modes.get(mode)
        if not isinstance(body, dict):
            errors.append(f"workflow.yaml: auth_modes.{mode} must be a mapping")
            continue
        waived = body.get("waived_human_gates")
        if not isinstance(waived, list):
            errors.append(
                f"workflow.yaml: auth_modes.{mode}.waived_human_gates must be a list"
            )
            continue
        for gate in waived:
            if str(gate) not in gate_names:
                errors.append(
                    f"workflow.yaml: auth_modes.{mode} waives unknown human gate {gate}"
                )
    for mode in sorted(set(modes) - set(VALID_AUTH_MODES)):
        errors.append(f"workflow.yaml: auth_modes defines unknown mode {mode}")
    return errors


def validate_spec_packet(spec_dir: Path) -> list[str]:
    errors: list[str] = []
    if not spec_dir.exists():
        return [f"spec packet does not exist: {spec_dir}"]
    if not spec_dir.is_dir():
        return [f"spec packet is not a directory: {spec_dir}"]

    match = re.fullmatch(r"GH([0-9]+)", spec_dir.name)
    if not match:
        errors.append(f"{spec_dir}: spec packet directory must be named GH<number>")
        issue_number = None
    else:
        issue_number = match.group(1)

    issue_tokens = []
    if issue_number:
        issue_tokens = [f"GH-{issue_number}", f"GH{issue_number}", f"#{issue_number}"]

    resolved_spec_dir = resolve_path(spec_dir, label=f"spec packet {spec_dir}")
    if resolved_spec_dir.name != spec_dir.name:
        errors.append(f"{spec_dir}: must preserve its GH<number> packet identity")
        return errors
    for name in ["product.md", "tech.md"]:
        path = spec_dir / name
        if not path.is_file():
            errors.append(f"{spec_dir}: missing {name}")
            continue
        resolved_path = resolve_path(path, label=f"spec artifact {path}")
        try:
            resolved_path.relative_to(resolved_spec_dir)
        except ValueError:
            errors.append(f"{path}: must stay within the spec packet")
            continue
        if resolved_path != resolved_spec_dir / name:
            errors.append(f"{path}: must preserve its declared artifact identity")
            continue
        text = read_text(resolved_path)
        if not text.strip():
            errors.append(f"{path}: must not be empty")
        if issue_tokens and not any(token in text for token in issue_tokens):
            errors.append(f"{path}: missing linked issue token {' or '.join(issue_tokens)}")
        if name == "tech.md" and (
            PLANNED_CHANGES_REQUIRED_MARKER in text
            or "specrail-planned-changes" in text
        ):
            try:
                manifest = parse_planned_changes_manifest(
                    text.encode("utf-8"), label=str(path)
                )
            except SpecRailError as exc:
                errors.append(str(exc))
            else:
                if manifest["version"] != 1:
                    errors.append(f"{path}: manifest version must be 1")
                if issue_number and manifest["issue"] != int(issue_number):
                    errors.append(
                        f"{path}: manifest issue must match GH{issue_number}"
                    )
                if manifest["complete"] is not True:
                    errors.append(f"{path}: manifest must declare complete=true")
                if not manifest["paths"]:
                    errors.append(f"{path}: manifest paths must not be empty")

    task_path = spec_dir / "tasks.md"
    if not task_path.is_file():
        errors.append(f"{spec_dir}: missing tasks.md")
    else:
        resolved_task_path = resolve_path(
            task_path,
            label=f"spec artifact {task_path}",
        )
        try:
            resolved_task_path.relative_to(resolved_spec_dir)
        except ValueError:
            errors.append(f"{task_path}: must stay within the spec packet")
        else:
            if resolved_task_path != resolved_spec_dir / "tasks.md":
                errors.append(
                    f"{task_path}: must preserve its declared artifact identity"
                )
                return errors
            errors.extend(validate_task_plan(resolved_task_path, issue_number))
    return errors


def spec_packet_sort_key(spec_dir: Path) -> tuple[int, int, str]:
    match = re.fullmatch(r"GH([0-9]+)", spec_dir.name)
    if match:
        return (0, int(match.group(1)), spec_dir.name)
    return (1, 0, str(spec_dir))


def discover_spec_packet_dirs(
    repo: Path,
    spec_root: PurePosixPath | None = None,
) -> list[Path]:
    uses_configured_root = spec_root is not None
    configured_root = spec_root if uses_configured_root else PurePosixPath("specs")
    specs_dir = resolve_spec_packet_root(repo, configured_root)
    if not specs_dir.exists():
        if not uses_configured_root:
            return []
        raise SpecRailError(
            "workflow.yaml: configured spec packet root does not exist"
        )
    if not specs_dir.is_dir():
        raise SpecRailError(
            "workflow.yaml: configured spec packet root is not a directory"
        )
    resolved_repo = resolve_path(repo, label="repository")
    spec_dirs: list[Path] = []
    for path in specs_dir.iterdir():
        if not re.fullmatch(r"GH([0-9]+)", path.name):
            continue
        relative_path = PurePosixPath(*path.relative_to(resolved_repo).parts)
        resolved_path = resolve_repo_path(
            repo,
            relative_path,
            label=f"spec packet {path.name}",
        )
        if resolved_path != specs_dir / path.name:
            raise SpecRailError(
                f"spec packet {path.name} resolves to a different name or "
                "configured path"
            )
        if not resolved_path.is_dir():
            raise SpecRailError(f"spec packet {path.name} is not a directory")
        spec_dirs.append(resolved_path)
    return sorted(spec_dirs, key=spec_packet_sort_key)


def select_spec_packet_dirs(
    repo: Path,
    raw_spec_dirs: list[str],
    *,
    all_specs: bool,
    spec_root: PurePosixPath | None = None,
) -> list[Path]:
    spec_dirs: list[Path] = []
    configured_root = spec_root if spec_root is not None else PurePosixPath("specs")
    resolved_root = resolve_spec_packet_root(repo, configured_root)
    if all_specs:
        spec_dirs.extend(discover_spec_packet_dirs(repo, configured_root))
    for raw_spec_dir in raw_spec_dirs:
        resolved_spec_dir = resolve_repo_path(
            repo,
            raw_spec_dir,
            label=f"spec directory {raw_spec_dir!r}",
        )
        lexical_name = PurePosixPath(raw_spec_dir.rstrip("/")).name
        if resolved_spec_dir.name != lexical_name:
            raise SpecRailError(
                f"spec directory {raw_spec_dir!r} resolves to a different packet identity"
            )
        if resolved_spec_dir != resolved_root / lexical_name:
            raise SpecRailError(
                f"spec directory {raw_spec_dir!r} must be an immediate child of the "
                "configured spec packet root"
            )
        spec_dirs.append(resolved_spec_dir)

    unique_spec_dirs: list[Path] = []
    seen: set[Path] = set()
    for spec_dir in spec_dirs:
        if spec_dir in seen:
            continue
        seen.add(spec_dir)
        unique_spec_dirs.append(spec_dir)

    if all_specs:
        return sorted(unique_spec_dirs, key=spec_packet_sort_key)
    return unique_spec_dirs


def validate_task_plan(path: Path, issue_number: str | None) -> list[str]:
    errors: list[str] = []
    text = read_text(path)
    if not text.strip():
        return [f"{path}: must not be empty"]
    prefix = f"SP{issue_number}-T" if issue_number else "SP"
    ids: list[str] = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        if "- [" not in line:
            continue
        match = re.search(r"`([^`]+)`", line)
        if not match:
            errors.append(f"{path}:{line_number}: task is missing stable ID")
            continue
        task_id = match.group(1)
        ids.append(task_id)
        if issue_number and not task_id.startswith(prefix):
            errors.append(f"{path}:{line_number}: task ID {task_id} must start with {prefix}")
        for token in ["Owner:", "Done when:", "Verify:"]:
            if token not in line:
                errors.append(f"{path}:{line_number}: task {task_id} missing {token}")
    if not ids:
        errors.append(f"{path}: no task checklist items found")
    duplicates = sorted({task_id for task_id in ids if ids.count(task_id) > 1})
    for duplicate in duplicates:
        errors.append(f"{path}: duplicate task ID {duplicate}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate a SpecRail workflow pack."
    )
    parser.add_argument("--repo", default=".", help="Workflow pack root")
    parser.add_argument(
        "--spec-dir",
        action="append",
        default=[],
        help="Optional GH<number> spec packet directory to validate",
    )
    parser.add_argument(
        "--all-specs",
        action="store_true",
        help="Validate every configured GH<number> spec packet under the repo",
    )
    args = parser.parse_args()

    errors: list[str] = []
    try:
        repo = resolve_path(Path(args.repo), label="repository")
        config = load_pack(repo)
        configured_spec_paths = spec_packet_artifact_paths(config, 1)
        configured_spec_root = PurePosixPath(
            configured_spec_paths["spec_packet"]
        ).parent
        resolve_spec_packet_root(repo, configured_spec_root)
        errors.extend(validate_required_files(repo))
        errors.extend(validate_required_file_globs(repo))
        errors.extend(validate_tokens(repo))
        errors.extend(validate_pack_assets(repo))
        errors.extend(validate_state_graph(config))
        errors.extend(validate_labels(config))
        errors.extend(validate_action_policy(config))
        errors.extend(validate_sensitive_registry(config))
        errors.extend(validate_impl_branch_template(config))
        errors.extend(validate_auth_mode(config))
        errors.extend(validate_skills_lock(repo))
        for spec_dir in select_spec_packet_dirs(
            repo,
            args.spec_dir,
            all_specs=args.all_specs,
            spec_root=configured_spec_root,
        ):
            errors.extend(validate_spec_packet(spec_dir))
    except SpecRailError as exc:
        errors.append(str(exc))

    if errors:
        print("SpecRail check failed")
        for error in errors:
            print(f"- {error}")
        return 1

    print("SpecRail check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Evaluate deterministic PR merge-readiness evidence.

The gate is intentionally offline. GitHub or threads adapters may collect the
evidence JSON, but this script only evaluates it and never writes remote state.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from pr_review_contract import evaluate_review_contract
from sensitive_enforcement import evaluate_sensitive_evidence, sensitive_registry
from specrail_lib import PackConfig, SpecRailError, load_pack, resolve_path


CHECK_PASS_CONCLUSIONS = {"SUCCESS"}
CLEAN_MERGE_STATES = {"CLEAN"}
MERGE_PATHS = {"gh_pr_merge", "api_fallback", "merged_by_other"}


def _non_empty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _positive_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def _load_json(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise ValueError(f"cannot read evidence file {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ValueError(f"invalid evidence JSON {path}: {exc.msg}") from exc
    if not isinstance(data, dict):
        raise ValueError("evidence JSON must be an object")
    return data


def _check_items(evidence: dict[str, Any]) -> tuple[list[str], list[str], list[str]]:
    satisfied: list[str] = []
    missing: list[str] = []
    reasons: list[str] = []

    checks = evidence.get("checks")
    if not isinstance(checks, list) or not checks:
        missing.append("checks")
        reasons.append("CI/check evidence is missing")
        return satisfied, missing, reasons

    for index, item in enumerate(checks, start=1):
        if not isinstance(item, dict):
            reasons.append(f"check #{index} is not an object")
            continue
        name = str(item.get("name") or f"check #{index}")
        status = str(item.get("status") or "").upper()
        conclusion = str(item.get("conclusion") or "").upper()
        if status != "COMPLETED":
            reasons.append(f"{name} is not completed: {status or 'missing status'}")
            continue
        if conclusion not in CHECK_PASS_CONCLUSIONS:
            reasons.append(f"{name} did not pass: {conclusion or 'missing conclusion'}")
            continue
        satisfied.append(f"check passed: {name}")
    return satisfied, missing, reasons


def _issue_reference_items(
    evidence: dict[str, Any],
) -> tuple[list[str], list[str], list[str]]:
    satisfied: list[str] = []
    missing: list[str] = []
    reasons: list[str] = []

    if "issue_reference" not in evidence:
        return satisfied, missing, reasons
    relation = evidence["issue_reference"]
    if not isinstance(relation, dict):
        reasons.append("issue_reference must be an object")
        return satisfied, missing, reasons

    allowed_fields = {
        "number",
        "kind",
        "source",
        "verified",
        "state",
        "url",
        "closing_issue_numbers",
    }
    unknown_fields = sorted(set(relation) - allowed_fields)
    if unknown_fields:
        reasons.append(
            "issue_reference contains unsupported fields: " + ", ".join(unknown_fields)
        )

    number = relation.get("number")
    if not _positive_int(number):
        missing.append("issue_reference.number")
    elif number != evidence.get("linked_issue"):
        reasons.append("issue_reference.number must match linked_issue")

    if relation.get("verified") is not True:
        reasons.append("issue_reference.verified must be true")

    closing_issue_numbers = relation.get("closing_issue_numbers")
    valid_closing_numbers = isinstance(closing_issue_numbers, list) and all(
        _positive_int(item) for item in closing_issue_numbers
    )
    if not valid_closing_numbers:
        reasons.append("issue_reference.closing_issue_numbers must be a list of positive integers")
        closing_issue_numbers = []
    elif len(set(closing_issue_numbers)) != len(closing_issue_numbers):
        reasons.append("issue_reference.closing_issue_numbers must not contain duplicates")

    kind = relation.get("kind")
    source = relation.get("source")
    if kind == "partial":
        if source != "pr_body":
            reasons.append("issue_reference partial source must be pr_body")
        if relation.get("state") != "OPEN":
            reasons.append("issue_reference partial state must be OPEN")
        if _positive_int(number) and number in closing_issue_numbers:
            reasons.append("issue_reference partial target must not be closing")
    elif kind == "closing":
        if source != "closingIssuesReferences":
            reasons.append(
                "issue_reference closing source must be closingIssuesReferences"
            )
        if _positive_int(number) and number not in closing_issue_numbers:
            reasons.append(
                "issue_reference closing target must appear in closing_issue_numbers"
            )
    else:
        reasons.append("issue_reference.kind must be one of: closing, partial")

    if not missing and not reasons:
        satisfied.append(f"issue_reference: verified {kind} GH-{number}")
    return satisfied, missing, reasons


def _merge_record_items(evidence: dict[str, Any]) -> tuple[list[str], list[str], list[str]]:
    satisfied: list[str] = []
    missing: list[str] = []
    reasons: list[str] = []

    record = evidence.get("merge_record")
    if record is None:
        return satisfied, missing, reasons
    if not isinstance(record, dict):
        reasons.append("merge_record must be an object")
        return satisfied, missing, reasons

    merge_path = record.get("merge_path")
    if not _non_empty_string(merge_path):
        missing.append("merge_record.merge_path")
    elif merge_path not in MERGE_PATHS:
        allowed = ", ".join(sorted(MERGE_PATHS))
        reasons.append(f"merge_record.merge_path must be one of: {allowed}")
    else:
        satisfied.append(f"merge_path: {merge_path}")

    if record.get("remote_confirmed") is not True:
        reasons.append(
            "merge_record.remote_confirmed must be true: confirm the merge "
            "outcome via a remote query (gh pr view --json merged,mergeCommit) "
            "before recording success or failure"
        )
    elif not _non_empty_string(record.get("merge_commit_sha")):
        missing.append("merge_record.merge_commit_sha")
    else:
        satisfied.append(f"merge remotely confirmed: {record['merge_commit_sha']}")

    outcome = record.get("branch_deletion_outcome")
    if outcome is not None and not _non_empty_string(outcome):
        reasons.append("merge_record.branch_deletion_outcome must be a non-empty string or null")

    return satisfied, missing, reasons


def _authorization_item(evidence: dict[str, Any]) -> tuple[list[str], list[str]]:
    authorization = evidence.get("human_authorization")
    if not isinstance(authorization, dict):
        return [], ["human_authorization"]
    missing = []
    for key in ["actor", "source"]:
        if not _non_empty_string(authorization.get(key)):
            missing.append(f"human_authorization.{key}")
    if missing:
        return [], missing
    return [f"human authorization from {authorization['actor']} via {authorization['source']}"], []


def evaluate_pr_gate(
    evidence: dict[str, Any],
    repo: Path | None = None,
    config: PackConfig | None = None,
) -> dict[str, Any]:
    """Evaluate merge-readiness evidence and return a stable decision object."""

    reasons: list[str] = []
    satisfied: list[str] = []
    missing: list[str] = []
    sensitive_classification: dict[str, Any] | None = None
    sensitive_reasons: list[str] = []

    if _positive_int(evidence.get("pr")):
        satisfied.append(f"pr: {evidence['pr']}")
    else:
        missing.append("pr")

    state = str(evidence.get("state") or "").upper()
    if state == "OPEN":
        satisfied.append("PR state is OPEN")
    elif state:
        reasons.append(f"PR state must be OPEN; got {state}")
    else:
        missing.append("state")

    if evidence.get("is_draft") is False:
        satisfied.append("PR is not draft")
    elif "is_draft" not in evidence:
        missing.append("is_draft")
    else:
        reasons.append("draft PR cannot merge")

    if _non_empty_string(evidence.get("head_sha")):
        satisfied.append(f"head_sha: {evidence['head_sha']}")
    else:
        missing.append("head_sha")

    if _positive_int(evidence.get("linked_issue")):
        satisfied.append(f"linked_issue: {evidence['linked_issue']}")
    else:
        missing.append("linked_issue")

    merge_state = str(evidence.get("merge_state") or "").upper()
    if merge_state in CLEAN_MERGE_STATES:
        satisfied.append(f"merge_state: {merge_state}")
    elif merge_state:
        reasons.append(f"merge_state must be CLEAN; got {merge_state}")
    else:
        missing.append("merge_state")

    for checker in [
        _check_items,
        _issue_reference_items,
        _merge_record_items,
    ]:
        checker_satisfied, checker_missing, checker_reasons = checker(evidence)
        satisfied.extend(checker_satisfied)
        missing.extend(checker_missing)
        reasons.extend(checker_reasons)

    review_satisfied, review_missing, review_reasons = evaluate_review_contract(
        evidence,
        repo,
    )
    satisfied.extend(review_satisfied)
    missing.extend(review_missing)
    reasons.extend(review_reasons)

    auth_satisfied, auth_missing = _authorization_item(evidence)
    satisfied.extend(auth_satisfied)
    missing.extend(auth_missing)

    has_sensitive_evidence = any(
        key in evidence
        for key in [
            "enforcement_sensitive",
            "sensitive_classification",
            "approved_spec",
        ]
    )
    if config is None and repo is not None:
        config = load_pack(resolve_path(repo, label="repository"))
    if config is not None:
        registry = sensitive_registry(config)
        has_sensitive_evidence = has_sensitive_evidence or bool(
            registry["paths"] or registry["specs"]
        )
    if has_sensitive_evidence:
        if repo is None:
            sensitive_reasons.append(
                "repository checkout is required to revalidate enforcement-sensitive evidence"
            )
        elif config is None:
            sensitive_reasons.append(
                "workflow configuration is required to revalidate enforcement-sensitive evidence"
            )
        else:
            sensitive_classification, sensitive_satisfied, sensitive_reasons = (
                evaluate_sensitive_evidence(
                    config,
                    resolve_path(repo, label="repository"),
                    evidence,
                    expected_source="github_changed_files",
                    issue=evidence.get("linked_issue"),
                    expected_base_ref=evidence.get("base_ref"),
                    expected_base_head=evidence.get("base_sha"),
                )
            )
            satisfied.extend(sensitive_satisfied)
        if sensitive_reasons:
            reasons.extend(sensitive_reasons)
            missing.append("sensitive_enforcement")

    deterministic_missing = [item for item in missing if not item.startswith("human_authorization")]
    if reasons or deterministic_missing:
        decision = "blocked"
    elif auth_missing:
        decision = "needs_human"
    else:
        decision = "allowed"

    blocked_actions = []
    if decision in {"blocked", "needs_human"}:
        blocked_actions.append("merge")
    if decision == "blocked":
        blocked_actions.append("final_approval")

    return {
        "decision": decision,
        "pr": evidence.get("pr"),
        "linked_issue": evidence.get("linked_issue"),
        "issue_reference": evidence.get("issue_reference"),
        "head_sha": evidence.get("head_sha"),
        "review_source": evidence.get("review_source"),
        "gate_query_completed_at": evidence.get("gate_query_completed_at"),
        "gate_query_head_sha": evidence.get("gate_query_head_sha"),
        "enforcement_sensitive": bool(
            evidence.get("enforcement_sensitive") is True
            or (
                sensitive_classification
                and sensitive_classification.get("enforcement_sensitive")
            )
        ),
        "sensitive_classification": sensitive_classification,
        "reasons": sorted(set(reasons)),
        "satisfied": sorted(set(satisfied)),
        "missing": sorted(set(missing)),
        "blocked_actions": blocked_actions,
        "verification_commands": [
            "python3 checks/pr_gate.py --repo . --evidence <evidence.json>",
            "python3 checks/check_workflow.py --repo .",
        ],
    }


def print_gate_human(result: dict[str, Any]) -> None:
    print(f"decision: {result['decision']}")
    if result.get("pr"):
        print(f"pr: {result['pr']}")
    if result.get("linked_issue"):
        print(f"linked_issue: GH-{result['linked_issue']}")
    if result.get("head_sha"):
        print(f"head_sha: {result['head_sha']}")
    if result["reasons"]:
        print("reasons:")
        for reason in result["reasons"]:
            print(f"- {reason}")
    if result["missing"]:
        print("missing:")
        for item in result["missing"]:
            print(f"- {item}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Evaluate SpecRail PR merge-readiness evidence."
    )
    parser.add_argument("--repo", default=".", help="Repository root, kept for CLI symmetry")
    parser.add_argument("--evidence", required=True, help="PR evidence JSON file")
    parser.add_argument(
        "--mode",
        default="dry_run",
        choices=["dry_run", "advisory", "required"],
        help="Evaluation enforcement mode",
    )
    parser.add_argument("--json", action="store_true", help="Print JSON output")
    args = parser.parse_args()

    try:
        evidence = _load_json(Path(args.evidence))
        repo = resolve_path(Path(args.repo), label="repository")
        result = evaluate_pr_gate(evidence, repo=repo, config=load_pack(repo))
    except ValueError as exc:
        result = {
            "decision": "blocked",
            "pr": None,
            "linked_issue": None,
            "head_sha": None,
            "reasons": [str(exc)],
            "satisfied": [],
            "missing": [],
            "blocked_actions": ["merge", "final_approval"],
            "verification_commands": ["python3 checks/pr_gate.py --repo . --evidence <evidence.json>"],
        }

    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        print_gate_human(result)

    if result["decision"] == "blocked":
        return 1
    if result["decision"] == "needs_human" and args.mode == "required":
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

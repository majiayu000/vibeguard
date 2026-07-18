#!/usr/bin/env python3
"""Collect read-only GitHub PR evidence for the offline SpecRail PR gate."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from github_evidence_common import EvidenceError, json_object
from github_approved_spec_evidence import collect_approval_metadata
from github_issue_reference import (
    normalize_issue_reference,
    normalize_linked_issue, references_partial_issue, relation_snapshot,
)
from github_pr_snapshot import (
    assert_same_pr_file_snapshot, collect_pr_file_snapshot, derive_spec_refs,
    enforcement_declaration,
)
from github_review_evidence import (
    build_human_authorization,
    build_self_review_authorization,
    load_lane_failures,
    load_resolver_role_map,
    normalize_review_threads,
)
from sensitive_enforcement import (
    approved_spec_source_commits,
    build_approved_spec_evidence,
    classify_sensitive_changes,
    sensitive_registry,
)
from review_result_semantics import ReviewSemanticError, load_review_manifest
from specrail_lib import PackConfig, SpecRailError, load_pack, resolve_path


PR_VIEW_FIELDS = [
    "number", "state", "isDraft", "headRefOid", "mergeStateStatus", "body",
    "closingIssuesReferences", "statusCheckRollup", "reviews",
]

REVIEW_THREADS_QUERY = """
query SpecRailReviewThreads($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100) {
        nodes {
          id isResolved isOutdated
          resolvedBy { login }
          comments(first: 1) {
            nodes {
              id url author { login }
            }
          }
        }
      }
    }
  }
}
""".strip()

REPO_PATTERN = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
STATUS_CONTEXT_STATES = {"SUCCESS", "FAILURE", "ERROR", "PENDING", "EXPECTED"}
REVIEW_SOURCES = {"independent_lane", "self_review"}
def parse_github_repo(raw: str) -> tuple[str, str]:
    value = raw.strip()
    if not REPO_PATTERN.fullmatch(value):
        raise EvidenceError("GitHub repository must use OWNER/REPO format")
    owner, name = value.split("/", 1)
    if owner in {".", ".."} or name in {".", ".."}:
        raise EvidenceError("GitHub repository owner and name must be explicit")
    return owner, name


def parse_pr_number(raw: str) -> int:
    try:
        value = int(raw)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("PR number must be a positive integer") from exc
    if value <= 0:
        raise argparse.ArgumentTypeError("PR number must be a positive integer")
    return value


def parse_issue_number(raw: str) -> int:
    try:
        value = int(raw)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("issue number must be a positive integer") from exc
    if value <= 0:
        raise argparse.ArgumentTypeError("issue number must be a positive integer")
    return value


def run_gh_json(args: list[str]) -> Any:
    command = ["gh", *args]
    try:
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError as exc:
        raise EvidenceError("gh executable was not found in PATH") from exc

    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip() or "no output"
        raise EvidenceError(f"gh command failed: {' '.join(command[:4])}: {detail}")

    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise EvidenceError(f"gh command returned invalid JSON: {exc.msg}") from exc
    return payload


def collect_pr_view(github_repo: str, pr_number: int) -> dict[str, Any]:
    return json_object(run_gh_json(
        [
            "pr",
            "view",
            str(pr_number),
            "--repo",
            github_repo,
            "--json",
            ",".join(PR_VIEW_FIELDS),
        ]
    ), "gh pr view response")


def collect_issue_view(github_repo: str, issue_number: int) -> dict[str, Any]:
    return json_object(run_gh_json(
        [
            "issue",
            "view",
            str(issue_number),
            "--repo",
            github_repo,
            "--json",
            "number,state,url",
        ]
    ), "gh issue view response")


def collect_review_threads(owner: str, name: str, pr_number: int) -> dict[str, Any]:
    return json_object(run_gh_json(
        [
            "api",
            "graphql",
            "-F",
            f"owner={owner}",
            "-F",
            f"name={name}",
            "-F",
            f"number={pr_number}",
            "-f",
            f"query={REVIEW_THREADS_QUERY}",
        ]
    ), "review threads GraphQL response")


def _require_mapping(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise EvidenceError(f"{field} must be an object")
    return value


def _require_list(value: Any, field: str) -> list[Any]:
    if not isinstance(value, list):
        raise EvidenceError(f"{field} must be a list")
    return value


def _require_positive_int(payload: dict[str, Any], field: str) -> int:
    value = payload.get(field)
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        raise EvidenceError(f"{field} must be a positive integer")
    return value


def _require_string(payload: dict[str, Any], field: str) -> str:
    value = payload.get(field)
    if not isinstance(value, str) or not value.strip():
        raise EvidenceError(f"{field} must be a non-empty string")
    return value.strip()


def _require_bool(payload: dict[str, Any], field: str) -> bool:
    value = payload.get(field)
    if not isinstance(value, bool):
        raise EvidenceError(f"{field} must be a boolean")
    return value


def _author_login(value: Any, fallback: str) -> str:
    if isinstance(value, dict) and isinstance(value.get("login"), str) and value["login"].strip():
        return value["login"].strip()
    if isinstance(value, str) and value.strip():
        return value.strip()
    return fallback


def _normalize_status_context(item: dict[str, Any]) -> tuple[str, str]:
    state = str(item.get("state") or "").upper()
    if state not in STATUS_CONTEXT_STATES:
        return "", ""
    if state == "SUCCESS":
        return "COMPLETED", "SUCCESS"
    if state in {"PENDING", "EXPECTED"}:
        return "IN_PROGRESS", ""
    return "COMPLETED", state


def _rollup_items(value: Any) -> list[Any]:
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        nodes = value.get("nodes")
        if isinstance(nodes, list):
            return nodes
    raise EvidenceError("statusCheckRollup must be a list or nodes object")


def normalize_checks(value: Any) -> list[dict[str, str]]:
    checks: list[dict[str, str]] = []
    for index, item in enumerate(_rollup_items(value), start=1):
        if not isinstance(item, dict):
            raise EvidenceError(f"statusCheckRollup item #{index} must be an object")
        name = str(item.get("name") or item.get("context") or item.get("workflowName") or f"check #{index}")
        status = str(item.get("status") or "").upper()
        conclusion = str(item.get("conclusion") or "").upper()
        if not status and not conclusion:
            status, conclusion = _normalize_status_context(item)
        if not status and conclusion == "SUCCESS":
            status = "COMPLETED"
        check = {
            "name": name,
            "status": status,
            "conclusion": conclusion,
        }
        url = item.get("detailsUrl") or item.get("targetUrl")
        if isinstance(url, str) and url.strip():
            check["url"] = url.strip()
        checks.append(check)
    return checks


def normalize_reviews(value: Any) -> list[dict[str, str]]:
    reviews = _require_list(value, "reviews")
    latest_by_author: dict[str, dict[str, str]] = {}
    author_order: list[str] = []
    for index, item in enumerate(reviews, start=1):
        if not isinstance(item, dict):
            raise EvidenceError(f"review item #{index} must be an object")
        state = str(item.get("state") or "").upper()
        if not state:
            continue
        author = _author_login(item.get("author"), f"review #{index}")
        if author not in latest_by_author:
            author_order.append(author)
        latest_by_author[author] = {"author": author, "state": state}
    return [latest_by_author[author] for author in author_order]


def build_evidence(
    pr_payload: dict[str, Any],
    threads_payload: dict[str, Any],
    authorization: dict[str, str] | None = None,
    merge_dispatched_at: str | None = None,
    merge_head_sha: str | None = None,
    review_source: str | None = None,
    lane_failures: list[dict[str, Any]] | None = None,
    self_review_authorization: dict[str, str] | None = None,
    resolver_roles: dict[str, str] | None = None,
    expected_issue: int | None = None,
    issue_payload: dict[str, Any] | None = None,
    repo: Path | None = None,
    config: PackConfig | None = None,
    repository: str | None = None,
    approval_metadata: dict[str, Any] | None = None,
    pr_snapshot: dict[str, Any] | None = None,
    review_evidence: dict[str, Any] | None = None,
    gate_started_at: str | None = None,
) -> dict[str, Any]:
    head_sha = _require_string(pr_payload, "headRefOid")
    linked_issue, issue_reference = normalize_issue_reference(
        pr_payload,
        expected_issue,
        issue_payload,
    )
    evidence: dict[str, Any] = {
        "pr": _require_positive_int(pr_payload, "number"),
        "state": _require_string(pr_payload, "state").upper(),
        "is_draft": _require_bool(pr_payload, "isDraft"),
        "head_sha": head_sha,
        "gate_started_at": gate_started_at
        or datetime.now(timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
        "gate_query_completed_at": datetime.now(timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
        "gate_query_head_sha": head_sha,
        "merge_state": _require_string(pr_payload, "mergeStateStatus").upper(),
        "linked_issue": linked_issue,
        "checks": normalize_checks(pr_payload.get("statusCheckRollup")),
        "reviews": normalize_reviews(pr_payload.get("reviews")),
        "review_threads": normalize_review_threads(threads_payload, resolver_roles),
        "lane_failures": lane_failures or [],
    }
    if issue_reference is not None:
        evidence["issue_reference"] = issue_reference
    if repo is not None and config is not None:
        declaration = enforcement_declaration(pr_payload.get("body"))
        registry = sensitive_registry(config)
        if declaration is not None or registry["paths"] or registry["specs"]:
            if not isinstance(pr_snapshot, dict) or pr_snapshot.get("head_sha") != head_sha:
                raise EvidenceError(
                    "complete PR file snapshot is required for sensitive classification"
                )
            try:
                classification = classify_sensitive_changes(
                    config,
                    repo,
                    pr_snapshot.get("paths"),
                    derive_spec_refs(config, repo, linked_issue, pr_snapshot.get("paths")),
                    source="github_changed_files",
                )
            except SpecRailError as exc:
                raise EvidenceError(str(exc)) from exc
            evidence["repository"] = repository
            evidence["base_ref"] = pr_snapshot.get("base_ref")
            evidence["base_sha"] = pr_snapshot.get("base_sha")
            evidence["default_base_ref"] = pr_snapshot.get("default_base_ref")
            evidence["default_base_sha"] = pr_snapshot.get("default_base_sha")
            evidence["changed_files_count"] = pr_snapshot.get("path_count")
            evidence["changed_files_sha256"] = pr_snapshot.get("paths_sha256")
            evidence["sensitive_classification"] = classification
            if declaration is not None:
                evidence["enforcement_sensitive"] = declaration
            if declaration is True or classification["enforcement_sensitive"]:
                if not isinstance(repository, str) or not repository.strip():
                    raise EvidenceError(
                        "enforcement-sensitive PR requires repository identity"
                    )
                if linked_issue is None:
                    raise EvidenceError(
                        "enforcement-sensitive PR requires a linked issue"
                    )
                if not isinstance(approval_metadata, dict):
                    raise EvidenceError(
                        "enforcement-sensitive PR requires trusted approval metadata"
                    )
                if (
                    approval_metadata.get("state_source") != "label"
                    or approval_metadata.get("state_trusted") is not True
                ):
                    raise EvidenceError(
                        "approved spec requires trusted maintainer label evidence"
                    )
                approval_default = (
                    approval_metadata.get("default_base_ref"),
                    approval_metadata.get("default_base_sha"),
                )
                snapshot_default = (
                    pr_snapshot.get("default_base_ref"),
                    pr_snapshot.get("default_base_sha"),
                )
                if approval_default != snapshot_default:
                    raise EvidenceError(
                        "approved-spec and PR snapshots disagree on trusted default base"
                    )
                try:
                    evidence["approved_spec"] = build_approved_spec_evidence(
                        config,
                        repo,
                        repository=str(repository or ""),
                        issue=linked_issue,
                        spec_revisions=approval_metadata.get("spec_revisions"),
                        approved_at=str(approval_metadata.get("approved_at") or ""),
                        maintainer_actor=str(
                            approval_metadata.get("maintainer_actor") or ""
                        ),
                        gated_head_sha=head_sha,
                        default_base_ref=snapshot_default[0],
                        default_base_sha=snapshot_default[1],
                    )
                except SpecRailError as exc:
                    raise EvidenceError(str(exc)) from exc
    if review_evidence is not None:
        derived_source = review_evidence.get("review_source")
        if derived_source not in REVIEW_SOURCES:
            raise EvidenceError("review manifest must derive a supported review_source")
        if review_source is not None and review_source.strip() != derived_source:
            raise EvidenceError("--review-source conflicts with trusted review manifest")
        evidence["review_source"] = derived_source
        evidence["review_evidence"] = review_evidence
        evidence["review_completed_at"] = review_evidence.get("review_completed_at")
    if authorization is not None:
        evidence["human_authorization"] = authorization
    if self_review_authorization is not None:
        evidence["self_review_authorization"] = self_review_authorization
    provided_merge = [value for value in [merge_dispatched_at, merge_head_sha] if value is not None]
    if provided_merge:
        if not merge_dispatched_at or not merge_dispatched_at.strip() or not merge_head_sha or not merge_head_sha.strip():
            raise EvidenceError(
                "--merge-dispatched-at and --merge-head-sha must be provided together"
            )
        evidence["merge_dispatched_at"] = merge_dispatched_at.strip()
        evidence["merge_head_sha"] = merge_head_sha.strip()
    return evidence


def collect_evidence(
    github_repo: str,
    pr_number: int,
    authorization: dict[str, str] | None,
    merge_dispatched_at: str | None = None,
    merge_head_sha: str | None = None,
    review_source: str | None = None,
    lane_failures: list[dict[str, Any]] | None = None,
    self_review_authorization: dict[str, str] | None = None,
    resolver_roles: dict[str, str] | None = None,
    expected_issue: int | None = None,
    repo: Path | None = None,
    config: PackConfig | None = None,
    review_manifest: str | None = None,
) -> dict[str, Any]:
    if expected_issue is not None and (
        not isinstance(expected_issue, int)
        or isinstance(expected_issue, bool)
        or expected_issue <= 0
    ):
        raise EvidenceError("expected issue must be a positive integer")
    gate_started_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace(
        "+00:00", "Z"
    )
    owner, name = parse_github_repo(github_repo)
    pr_payload_before = collect_pr_view(github_repo, pr_number)
    head_sha_before = _require_string(pr_payload_before, "headRefOid")
    relation_snapshot_before = relation_snapshot(pr_payload_before)
    file_snapshot_before = None
    if repo is not None and config is not None and (enforcement_declaration(pr_payload_before.get("body")) is not None or any(sensitive_registry(config).values())):
        file_snapshot_before = collect_pr_file_snapshot(
            owner, name, pr_number, run_gh_json, run_gh_json)
        if file_snapshot_before["head_sha"] != head_sha_before:
            raise EvidenceError("PR view and file snapshot head SHA disagree")
    threads_payload = collect_review_threads(owner, name, pr_number)

    issue_payload = None
    closing_issue_numbers = list(relation_snapshot_before[1])
    if expected_issue is not None and expected_issue not in closing_issue_numbers:
        body = relation_snapshot_before[0]
        if not references_partial_issue(body, expected_issue):
            raise EvidenceError(
                f"PR body must contain a standalone Refs #{expected_issue} directive"
            )
        issue_payload = collect_issue_view(github_repo, expected_issue)

    approval_metadata = None
    if file_snapshot_before is not None:
        assert file_snapshot_before is not None
        declaration = enforcement_declaration(pr_payload_before.get("body"))
        registry = sensitive_registry(config)
        if declaration is not None or registry["paths"] or registry["specs"]:
            try:
                linked_issue, _ = normalize_issue_reference(
                    pr_payload_before, expected_issue, issue_payload
                )
                classification = classify_sensitive_changes(
                    config,
                    repo,
                    file_snapshot_before.get("paths"),
                    derive_spec_refs(
                        config, repo, linked_issue, file_snapshot_before.get("paths")
                    ),
                    source="github_changed_files",
                )
            except SpecRailError as exc:
                raise EvidenceError(str(exc)) from exc
            if declaration is True or classification["enforcement_sensitive"]:
                if linked_issue is None:
                    raise EvidenceError(
                        "enforcement-sensitive PR requires a linked issue"
                    )
                approval_metadata = collect_approval_metadata(
                    github_repo, linked_issue, run_gh_json,
                    spec_source_commits=approved_spec_source_commits(
                        config, repo, linked_issue,
                        default_base_ref=file_snapshot_before.get("default_base_ref"),
                        default_base_sha=file_snapshot_before.get("default_base_sha"),
                    ),
                )

    file_snapshot_after = None
    if file_snapshot_before is not None:
        file_snapshot_after = collect_pr_file_snapshot(
            owner, name, pr_number, run_gh_json, run_gh_json)
        assert file_snapshot_before is not None
        assert_same_pr_file_snapshot(file_snapshot_before, file_snapshot_after)

    pr_payload_after = collect_pr_view(github_repo, pr_number)
    head_sha_after = _require_string(pr_payload_after, "headRefOid")
    if head_sha_before != head_sha_after:
        raise EvidenceError(
            "PR head changed while collecting gate evidence; rerun PR evidence collection"
        )
    relation_snapshot_after = relation_snapshot(pr_payload_after)
    if relation_snapshot_before != relation_snapshot_after:
        raise EvidenceError(
            "PR issue relation changed while collecting gate evidence; rerun PR evidence collection"
        )

    review_evidence = None
    if review_manifest is not None:
        if repo is None:
            raise EvidenceError("--review-manifest requires a repository checkout")
        try:
            review_evidence = load_review_manifest(
                repo,
                review_manifest,
                expected_pr=pr_number,
                expected_head_sha=head_sha_after,
            )
        except ReviewSemanticError as exc:
            raise EvidenceError(str(exc)) from exc
    elif review_source is not None:
        raise EvidenceError(
            "--review-source alone cannot prove terminal review; --review-manifest is required"
        )

    return build_evidence(
        pr_payload_after,
        threads_payload,
        authorization,
        merge_dispatched_at,
        merge_head_sha,
        review_source,
        lane_failures,
        self_review_authorization,
        resolver_roles,
        expected_issue,
        issue_payload,
        repo,
        config,
        github_repo,
        approval_metadata,
        file_snapshot_after,
        review_evidence,
        gate_started_at,
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Collect read-only GitHub PR evidence for SpecRail pr_gate.py."
    )
    parser.add_argument("--github-repo", required=True, help="GitHub repository as OWNER/REPO")
    parser.add_argument("--repo", default=".", help="Local repository checkout")
    parser.add_argument("--pr", required=True, type=parse_pr_number, help="Pull request number")
    parser.add_argument(
        "--issue",
        type=parse_issue_number,
        help="Expected linked issue; required to verify a non-closing Refs directive",
    )
    parser.add_argument("--authorization-actor", help="Human authorizing merge")
    parser.add_argument("--authorization-source", help="Where authorization was recorded")
    parser.add_argument("--authorization-summary", help="Short authorization summary")
    parser.add_argument(
        "--review-source",
        choices=sorted(REVIEW_SOURCES),
        help="Review source for the PR gate evidence",
    )
    parser.add_argument(
        "--review-manifest",
        help="Repo-relative trusted manifest containing all reviewer lane artifacts",
    )
    parser.add_argument(
        "--lane-failures-json",
        help="JSON file containing lane_failures evidence",
    )
    parser.add_argument(
        "--resolver-role-map",
        help="JSON map or lane roster used to map resolver login to resolver_role",
    )
    parser.add_argument("--self-review-authorization-actor", help="Human authorizing self-review")
    parser.add_argument("--self-review-authorization-source", help="Where self-review authorization was recorded")
    parser.add_argument("--self-review-authorization-scope", help="Scope of self-review authorization")
    parser.add_argument("--self-review-authorization-summary", help="Short self-review authorization summary")
    parser.add_argument("--merge-dispatched-at", help="Optional merge dispatch timestamp for audit records")
    parser.add_argument("--merge-head-sha", help="Optional merge target head SHA for audit records")
    parser.add_argument("--json", action="store_true", help="Print JSON output")
    args = parser.parse_args()

    try:
        authorization = build_human_authorization(
            args.authorization_actor,
            args.authorization_source,
            args.authorization_summary,
        )
        self_review_authorization = build_self_review_authorization(
            args.self_review_authorization_actor,
            args.self_review_authorization_source,
            args.self_review_authorization_scope,
            args.self_review_authorization_summary,
        )
        lane_failures = load_lane_failures(args.lane_failures_json)
        resolver_roles = load_resolver_role_map(args.resolver_role_map)
        repo = resolve_path(Path(args.repo), label="repository")
        evidence = collect_evidence(
            args.github_repo,
            args.pr,
            authorization,
            args.merge_dispatched_at,
            args.merge_head_sha,
            args.review_source,
            lane_failures,
            self_review_authorization,
            resolver_roles,
            args.issue,
            repo,
            load_pack(repo),
            args.review_manifest,
        )
    except (EvidenceError, SpecRailError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    print(json.dumps(evidence, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())

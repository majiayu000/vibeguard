"""Terminal review, resolver, and ordering contract for the offline PR gate."""

from __future__ import annotations

from datetime import datetime
from pathlib import Path
import re
from typing import Any

from review_result_semantics import (
    ReviewSemanticError,
    evaluate_review_evidence,
    load_review_manifest,
)


ACTIVE_CHANGE_REQUESTS = {"CHANGES_REQUESTED"}
REVIEW_SOURCES = {"independent_lane", "self_review"}
LANE_FAILURE_KINDS = {"usage_limit", "crash", "zero_output", "closed", "other"}
BLOCKED_RESOLVER_ROLES = {"implementer", "orchestrator", "coordinator", "unknown"}


def _nonempty(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _parse_timestamp(value: Any) -> datetime | None:
    if not _nonempty(value):
        return None
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo is not None else None


def _scope_binds_pr(scope: Any, pr: Any) -> bool:
    if not _nonempty(scope) or not isinstance(pr, int) or isinstance(pr, bool):
        return False
    return re.search(rf"\bPR\s*#?\s*{pr}(?!\d)", str(scope), re.IGNORECASE) is not None


def _github_review_items(evidence: dict[str, Any]) -> tuple[list[str], list[str], list[str]]:
    satisfied: list[str] = []
    reasons: list[str] = []
    reviews = evidence.get("reviews", [])
    if not isinstance(reviews, list):
        return satisfied, [], ["reviews must be a list"]
    for index, review in enumerate(reviews, start=1):
        if not isinstance(review, dict):
            reasons.append(f"review #{index} is not an object")
            continue
        if str(review.get("state") or "").upper() in ACTIVE_CHANGE_REQUESTS:
            reasons.append(f"changes requested by {review.get('author') or f'review #{index}'}")
    if not reasons:
        satisfied.append("no active changes-requested review evidence")
    return satisfied, [], reasons


def _verified_reviewer_resolver(
    thread: dict[str, Any],
    review_evidence: dict[str, Any],
) -> bool:
    resolved_by = thread.get("resolved_by")
    original_author = thread.get("original_author")
    original_comment_id = thread.get("original_comment_id")
    lane_id = thread.get("lane_id")
    if (
        not _nonempty(lane_id)
        or not _nonempty(original_author)
        or not _nonempty(original_comment_id)
    ):
        return False
    roster = review_evidence.get("lane_roster", [])
    current_ids = review_evidence.get("current_artifact_ids", [])
    raw_artifacts = review_evidence.get("artifacts", [])
    artifacts = raw_artifacts if isinstance(raw_artifacts, list) else []
    for lane in roster if isinstance(roster, list) else []:
        if not isinstance(lane, dict):
            continue
        if lane.get("producer_identity") != resolved_by:
            continue
        if lane.get("lane_id") != lane_id:
            continue
        if not lane.get("successor_of"):
            return resolved_by == original_author
        original_lanes = [
            candidate
            for candidate in roster
            if isinstance(candidate, dict)
            and not candidate.get("successor_of")
            and candidate.get("producer_identity") == original_author
        ]
        if len(original_lanes) != 1:
            return False
        original_lane_id = original_lanes[0].get("lane_id")
        re_review_artifact_id = thread.get("re_review_artifact_id")
        verified_re_review = any(
            isinstance(artifact, dict)
            and artifact.get("artifact_id") == re_review_artifact_id
            and artifact.get("reviewer_lane") == lane_id
            and artifact.get("producer_identity") == resolved_by
            and artifact.get("head_sha") == review_evidence.get("head_sha")
            and artifact.get("status") == "completed"
            and artifact.get("verdict") in {"clean", "non_blocking"}
            for artifact in artifacts
        )
        return (
            lane.get("successor_of") == original_lane_id
            and original_lane_id == thread.get("successor_of")
            and re_review_artifact_id in current_ids
            and verified_re_review
        )
    return False


def _thread_items(evidence: dict[str, Any]) -> tuple[list[str], list[str], list[str]]:
    satisfied: list[str] = []
    missing: list[str] = []
    reasons: list[str] = []
    threads = evidence.get("review_threads")
    if not isinstance(threads, list):
        return satisfied, ["review_threads"], ["review thread evidence is missing"]
    review_evidence = evidence.get("review_evidence")
    if not isinstance(review_evidence, dict):
        review_evidence = {}
    unresolved: list[str] = []
    for index, thread in enumerate(threads, start=1):
        if not isinstance(thread, dict):
            unresolved.append(f"thread #{index}")
            continue
        identifier = str(thread.get("url") or thread.get("id") or f"thread #{index}")
        if thread.get("is_resolved") is not True:
            unresolved.append(identifier)
            continue
        if not _nonempty(thread.get("resolved_by")):
            missing.append(f"review_threads[{index}].resolved_by")
        role = thread.get("resolver_role")
        if not _nonempty(role):
            missing.append(f"review_threads[{index}].resolver_role")
            continue
        if role == "human":
            if thread.get("authorized_human_maintainer") is True:
                satisfied.append(
                    f"review thread resolved by human authorized maintainer: {identifier}"
                )
            else:
                reasons.append(
                    f"actionable review thread human resolver lacks maintainer authorization: {identifier}"
                )
        elif role == "reviewer_lane":
            if _verified_reviewer_resolver(thread, review_evidence):
                satisfied.append(f"review thread resolved by verified reviewer lane: {identifier}")
            else:
                reasons.append(
                    f"actionable review thread resolver lacks original/successor re-review evidence: {identifier}"
                )
        elif role in BLOCKED_RESOLVER_ROLES:
            reasons.append(f"review thread resolved by forbidden {role}: {identifier}")
        else:
            reasons.append(f"review thread resolver_role is unsupported: {role}")
    if unresolved:
        reasons.append("unresolved review threads: " + ", ".join(unresolved))
    else:
        satisfied.append("no unresolved active review threads")
    return satisfied, missing, reasons


def _self_review_items(evidence: dict[str, Any]) -> tuple[list[str], list[str], list[str]]:
    satisfied: list[str] = ["review_source: self_review"]
    missing: list[str] = []
    reasons: list[str] = []
    failures = evidence.get("lane_failures")
    if not isinstance(failures, list) or not failures:
        reasons.append("self_review requires recorded lane_failures")
    else:
        for index, failure in enumerate(failures, start=1):
            if not isinstance(failure, dict):
                continue
            if failure.get("pr") != evidence.get("pr"):
                reasons.append(f"lane_failures[{index}].pr must match pr")
            if failure.get("head_sha") != evidence.get("head_sha"):
                reasons.append(f"lane_failures[{index}].head_sha must match head_sha")
    authorization = evidence.get("self_review_authorization")
    if not isinstance(authorization, dict):
        return satisfied, ["self_review_authorization"], [
            *reasons,
            "self_review requires explicit self_review_authorization",
        ]
    for key in ["actor", "source", "scope"]:
        if not _nonempty(authorization.get(key)):
            missing.append(f"self_review_authorization.{key}")
    scope = authorization.get("scope")
    if _nonempty(scope) and (
        not _scope_binds_pr(scope, evidence.get("pr"))
        or not _nonempty(evidence.get("head_sha"))
        or str(evidence["head_sha"]) not in str(scope)
    ):
        reasons.append("self_review_authorization.scope must bind the same PR and head_sha")
    review_evidence = evidence.get("review_evidence")
    if not isinstance(review_evidence, dict) or review_evidence.get("human_final_review_required") is not True:
        reasons.append("self_review requires human_final_review_required=true")
    if not missing:
        satisfied.append(
            f"self-review authorization from {authorization['actor']} via {authorization['source']}"
        )
    return satisfied, missing, reasons


def _source_and_lane_items(
    evidence: dict[str, Any],
) -> tuple[list[str], list[str], list[str]]:
    satisfied: list[str] = []
    missing: list[str] = []
    reasons: list[str] = []
    source = evidence.get("review_source")
    review_evidence = evidence.get("review_evidence")
    if not _nonempty(source):
        return satisfied, ["review_source"], ["review_source evidence is missing"]
    if source not in REVIEW_SOURCES:
        return satisfied, missing, [
            f"review_source must be one of: {', '.join(sorted(REVIEW_SOURCES))}"
        ]
    if not isinstance(review_evidence, dict):
        return satisfied, ["review_evidence"], [
            "review_source alone cannot prove terminal review evidence"
        ]
    if review_evidence.get("review_source") != source:
        reasons.append("review_source must be derived from review_evidence")
    if source == "independent_lane":
        satisfied.append("review_source: independent_lane")
    else:
        nested_satisfied, nested_missing, nested_reasons = _self_review_items(evidence)
        satisfied.extend(nested_satisfied)
        missing.extend(nested_missing)
        reasons.extend(nested_reasons)

    failures = evidence.get("lane_failures")
    if not isinstance(failures, list):
        return satisfied, [*missing, "lane_failures"], [*reasons, "lane_failures must be a list"]
    for index, failure in enumerate(failures, start=1):
        if not isinstance(failure, dict):
            reasons.append(f"lane_failures[{index}] must be an object")
            continue
        for key in ["lane_id", "failure_kind", "observed_marker"]:
            if not _nonempty(failure.get(key)):
                missing.append(f"lane_failures[{index}].{key}")
        kind = failure.get("failure_kind")
        if _nonempty(kind) and kind not in LANE_FAILURE_KINDS:
            reasons.append(f"lane_failures[{index}].failure_kind is unsupported: {kind}")
    satisfied.append(
        f"lane failures recorded: {len(failures)}" if failures else "no lane failures recorded"
    )
    return satisfied, missing, reasons


def _terminal_items(evidence: dict[str, Any]) -> tuple[list[str], list[str], list[str]]:
    review_evidence = evidence.get("review_evidence")
    result = evaluate_review_evidence(
        review_evidence,
        expected_pr=evidence.get("pr"),
        expected_head_sha=evidence.get("head_sha"),
    )
    missing = [] if isinstance(review_evidence, dict) else ["review_evidence"]
    return result["satisfied"], missing, [
        *result["errors"],
        *result["blocking_reasons"],
    ]


def _manifest_trust_items(
    evidence: dict[str, Any],
    repo: Path | None,
) -> tuple[list[str], list[str], list[str]]:
    if repo is None:
        return [], [], []
    embedded = evidence.get("review_evidence")
    if not isinstance(embedded, dict):
        return [], ["review_evidence"], []
    manifest_path = embedded.get("manifest_path")
    if not _nonempty(manifest_path):
        return [], ["review_evidence.manifest_path"], []
    try:
        trusted = load_review_manifest(
            repo,
            str(manifest_path),
            expected_pr=evidence.get("pr"),
            expected_head_sha=evidence.get("head_sha"),
        )
    except ReviewSemanticError as exc:
        return [], [], [f"review manifest trust validation failed: {exc}"]

    def artifacts_without_paths(value: Any) -> Any:
        if not isinstance(value, list):
            return value
        return [
            {key: item for key, item in artifact.items() if key != "artifact_path"}
            if isinstance(artifact, dict)
            else artifact
            for artifact in value
        ]

    mismatches: list[str] = []
    for key in [
        "manifest_sha256",
        "pr",
        "head_sha",
        "review_source",
        "review_completed_at",
        "human_final_review_required",
        "lane_roster",
        "current_artifact_ids",
        "errors",
        "blocking_reasons",
    ]:
        if embedded.get(key) != trusted.get(key):
            mismatches.append(f"review_evidence.{key} differs from trusted manifest")
    if artifacts_without_paths(embedded.get("artifacts")) != artifacts_without_paths(
        trusted.get("artifacts")
    ):
        mismatches.append("review_evidence.artifacts differ from trusted manifest")
    if mismatches:
        return [], [], mismatches
    return ["review manifest revalidated from repository-safe paths"], [], []


def _ordering_items(evidence: dict[str, Any]) -> tuple[list[str], list[str], list[str]]:
    satisfied: list[str] = []
    missing: list[str] = []
    reasons: list[str] = []
    if "gate_completed_at" in evidence:
        reasons.append("gate_completed_at alias is unsupported; use canonical gate_query_completed_at")

    review_evidence = evidence.get("review_evidence")
    manifest_completed_at = (
        review_evidence.get("review_completed_at")
        if isinstance(review_evidence, dict)
        else None
    )
    if not _nonempty(manifest_completed_at):
        missing.append("review_evidence.review_completed_at")
    elif evidence.get("review_completed_at") != manifest_completed_at:
        reasons.append(
            "review_completed_at must match trusted review_evidence.review_completed_at"
        )

    fields = ["review_completed_at", "gate_started_at", "gate_query_completed_at"]
    times: dict[str, datetime] = {}
    for field in fields:
        parsed = _parse_timestamp(evidence.get(field))
        if parsed is None:
            missing.append(field)
            if evidence.get(field) is not None:
                reasons.append(f"{field} must be a timezone-aware ISO-8601 timestamp")
        else:
            times[field] = parsed
    if all(field in times for field in fields):
        if times["review_completed_at"] > times["gate_started_at"]:
            reasons.append("review must complete at or before gate start")
        else:
            satisfied.append("review completed before gate start")
        if times["gate_started_at"] > times["gate_query_completed_at"]:
            reasons.append("gate_started_at must be at or before gate_query_completed_at")
        else:
            satisfied.append("gate start precedes gate query completion")

    head_sha = evidence.get("head_sha")
    gate_head_sha = evidence.get("gate_query_head_sha")
    if not _nonempty(gate_head_sha):
        missing.append("gate_query_head_sha")
    elif gate_head_sha != head_sha:
        reasons.append("gate_query_head_sha must match head_sha")
    else:
        satisfied.append("gate_query_head_sha matches head_sha")

    merge_time = evidence.get("merge_dispatched_at")
    merge_head = evidence.get("merge_head_sha")
    if (merge_time is None) != (merge_head is None):
        missing.append("merge_ordering_pair")
        reasons.append("merge_dispatched_at and merge_head_sha must be provided together")
    elif merge_time is not None:
        parsed_merge = _parse_timestamp(merge_time)
        if parsed_merge is None:
            reasons.append("merge_dispatched_at must be a timezone-aware ISO-8601 timestamp")
        elif "gate_query_completed_at" in times and times["gate_query_completed_at"] >= parsed_merge:
            reasons.append("gate query must complete before merge dispatch")
        else:
            satisfied.append("merge dispatch ordered after gate query")
        if merge_head != gate_head_sha:
            reasons.append("merge_head_sha must match gate_query_head_sha")
        else:
            satisfied.append("merge_head_sha matches gate_query_head_sha")
    return satisfied, missing, reasons


def evaluate_review_contract(
    evidence: dict[str, Any],
    repo: Path | None = None,
) -> tuple[list[str], list[str], list[str]]:
    satisfied: list[str] = []
    missing: list[str] = []
    reasons: list[str] = []
    for checker in [
        _github_review_items,
        _thread_items,
        _terminal_items,
        _source_and_lane_items,
        _ordering_items,
    ]:
        nested_satisfied, nested_missing, nested_reasons = checker(evidence)
        satisfied.extend(nested_satisfied)
        missing.extend(nested_missing)
        reasons.extend(nested_reasons)
    trust_satisfied, trust_missing, trust_reasons = _manifest_trust_items(evidence, repo)
    satisfied.extend(trust_satisfied)
    missing.extend(trust_missing)
    reasons.extend(trust_reasons)
    return satisfied, missing, reasons

"""Shared semantic validation for terminal review artifacts and manifests."""

from __future__ import annotations

from datetime import datetime
import hashlib
import json
from pathlib import Path
from typing import Any

from schema_validation import validate_instance
from specrail_lib import SpecRailError, resolve_path, resolve_repo_path


REVIEW_STATUSES = {"completed", "pending", "failed", "cancelled", "superseded"}
TERMINAL_STATUSES = REVIEW_STATUSES - {"pending"}
REVIEW_VERDICTS = {"clean", "non_blocking", "changes_requested", "blocking"}
MERGE_READY_VERDICTS = {"clean", "non_blocking"}
REVIEW_SOURCES = {"independent_lane", "self_review"}
FINDING_SEVERITIES = {"critical", "important", "suggestion", "nit"}
PRIOR_FINDING_STATUSES = {"resolved", "unresolved", "obsolete"}


class ReviewSemanticError(SpecRailError):
    """Raised when a manifest cannot be trusted or parsed."""


def _nonempty(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _positive_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def parse_timestamp(value: Any, field: str, errors: list[str]) -> datetime | None:
    if not _nonempty(value):
        errors.append(f"{field} must be a non-empty timezone-aware ISO-8601 timestamp")
        return None
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        errors.append(f"{field} must be a timezone-aware ISO-8601 timestamp")
        return None
    if parsed.tzinfo is None:
        errors.append(f"{field} must be a timezone-aware ISO-8601 timestamp")
        return None
    return parsed


def _validate_finding(
    finding: Any,
    index: int,
    errors: list[str],
) -> dict[str, Any] | None:
    label = f"findings[{index}]"
    if not isinstance(finding, dict):
        errors.append(f"{label} must be an object")
        return None
    normalized: dict[str, Any] = {}
    for key in ["id", "summary"]:
        if not _nonempty(finding.get(key)):
            errors.append(f"{label}.{key} must be a non-empty string")
        else:
            normalized[key] = str(finding[key]).strip()
    severity = finding.get("severity")
    if severity not in FINDING_SEVERITIES:
        errors.append(f"{label}.severity must be one of: {', '.join(sorted(FINDING_SEVERITIES))}")
    else:
        normalized["severity"] = severity
    if not isinstance(finding.get("actionable"), bool):
        errors.append(f"{label}.actionable must be a boolean")
    else:
        normalized["actionable"] = finding["actionable"]
    return normalized


def _validate_prior_finding(
    finding: Any,
    index: int,
    errors: list[str],
) -> dict[str, Any] | None:
    label = f"prior_findings[{index}]"
    if not isinstance(finding, dict):
        errors.append(f"{label} must be an object")
        return None
    normalized: dict[str, Any] = {}
    for key in ["id", "source_head_sha", "summary"]:
        if not _nonempty(finding.get(key)):
            errors.append(f"{label}.{key} must be a non-empty string")
        else:
            normalized[key] = str(finding[key]).strip()
    status = finding.get("status")
    if status not in PRIOR_FINDING_STATUSES:
        errors.append(
            f"{label}.status must be one of: {', '.join(sorted(PRIOR_FINDING_STATUSES))}"
        )
    else:
        normalized["status"] = status
    closure_evidence = finding.get("closure_evidence")
    if status in {"resolved", "obsolete"} and not _nonempty(closure_evidence):
        errors.append(f"{label}.closure_evidence is required for {status}")
    elif _nonempty(closure_evidence):
        normalized["closure_evidence"] = str(closure_evidence).strip()
    return normalized


def validate_review_artifact(
    artifact: Any,
    *,
    expected_pr: int | None = None,
    expected_head_sha: str | None = None,
    expected_lane: str | None = None,
    expected_producer: str | None = None,
) -> dict[str, Any]:
    """Validate one v2 artifact without deciding final merge authority."""

    errors: list[str] = []
    blockers: list[str] = []
    if not isinstance(artifact, dict):
        return {"valid": False, "errors": ["review artifact must be an object"], "blocking_reasons": []}

    required_strings = [
        "artifact_id",
        "reviewer_lane",
        "producer_identity",
        "review_source",
        "head_sha",
        "review_started_at",
        "status",
        "verdict",
        "body",
    ]
    for key in required_strings:
        if not _nonempty(artifact.get(key)):
            errors.append(f"{key} must be a non-empty string")
    if not _positive_int(artifact.get("pr")):
        errors.append("pr must be a positive integer")
    if expected_pr is not None and artifact.get("pr") != expected_pr:
        errors.append(f"pr must match manifest PR {expected_pr}")
    if expected_head_sha is not None and artifact.get("head_sha") != expected_head_sha:
        errors.append("head_sha must match the expected final head")
    if expected_lane is not None and artifact.get("reviewer_lane") != expected_lane:
        errors.append("reviewer_lane must match its manifest lane")
    if expected_producer is not None and artifact.get("producer_identity") != expected_producer:
        errors.append("producer_identity must match its manifest lane")

    source = artifact.get("review_source")
    if source not in REVIEW_SOURCES:
        errors.append(f"review_source must be one of: {', '.join(sorted(REVIEW_SOURCES))}")
    status = artifact.get("status")
    if status not in REVIEW_STATUSES:
        errors.append(f"status must be one of: {', '.join(sorted(REVIEW_STATUSES))}")
    verdict = artifact.get("verdict")
    if verdict not in REVIEW_VERDICTS:
        errors.append(f"verdict must be one of: {', '.join(sorted(REVIEW_VERDICTS))}")

    started = parse_timestamp(artifact.get("review_started_at"), "review_started_at", errors)
    completed = None
    if status == "pending" and artifact.get("review_completed_at") is None:
        completed = None
    else:
        completed = parse_timestamp(
            artifact.get("review_completed_at"), "review_completed_at", errors
        )
    if started is not None and completed is not None and started > completed:
        errors.append("review_started_at must be at or before review_completed_at")

    if not isinstance(artifact.get("human_final_review_required"), bool):
        errors.append("human_final_review_required must be a boolean")
    elif source == "self_review" and artifact["human_final_review_required"] is not True:
        errors.append("self_review requires human_final_review_required=true")

    findings = artifact.get("findings")
    normalized_findings: list[dict[str, Any]] = []
    if not isinstance(findings, list):
        errors.append("findings must be a list")
    else:
        for index, finding in enumerate(findings):
            normalized = _validate_finding(finding, index, errors)
            if normalized is not None:
                normalized_findings.append(normalized)
        ids = [item.get("id") for item in normalized_findings if item.get("id")]
        if len(ids) != len(set(ids)):
            errors.append("findings IDs must be unique")

    prior = artifact.get("prior_findings")
    normalized_prior: list[dict[str, Any]] = []
    if not isinstance(prior, list):
        errors.append("prior_findings must be a list")
    else:
        for index, finding in enumerate(prior):
            normalized = _validate_prior_finding(finding, index, errors)
            if normalized is not None:
                normalized_prior.append(normalized)
        prior_keys = [
            (item.get("id"), item.get("source_head_sha"))
            for item in normalized_prior
            if item.get("id") and item.get("source_head_sha")
        ]
        if len(prior_keys) != len(set(prior_keys)):
            errors.append("prior_findings id/source_head_sha pairs must be unique")

    if not isinstance(artifact.get("comments"), list):
        errors.append("comments must be a list")

    if status != "completed":
        blockers.append(f"review status is not completed: {status}")
    if verdict not in MERGE_READY_VERDICTS:
        blockers.append(f"review verdict is not merge-ready: {verdict}")
    if verdict == "clean" and normalized_findings:
        blockers.append("clean verdict requires zero findings")
    for finding in normalized_findings:
        if finding.get("severity") in {"critical", "important"} or finding.get("actionable") is True:
            blockers.append(f"blocking current-head finding: {finding.get('id', '<missing>')}")
    for finding in normalized_prior:
        if finding.get("status") == "unresolved":
            blockers.append(f"unresolved prior finding: {finding.get('id', '<missing>')}")

    return {
        "valid": not errors,
        "errors": errors,
        "blocking_reasons": blockers,
        "artifact": artifact,
    }


def _load_manifest_json(repo: Path, raw_path: str, label: str) -> tuple[Path, dict[str, Any]]:
    try:
        path = resolve_repo_path(repo, raw_path, label=label)
    except SpecRailError as exc:
        raise ReviewSemanticError(
            f"{label} must use repo-relative POSIX paths within the repository: {exc}"
        ) from exc
    if not path.is_file():
        raise ReviewSemanticError(f"{label} is missing: {raw_path}")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise ReviewSemanticError(f"cannot read {label} {raw_path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ReviewSemanticError(f"{label} is not valid JSON: {exc.msg}") from exc
    if not isinstance(data, dict):
        raise ReviewSemanticError(f"{label} must contain a JSON object")
    return path, data


def load_review_manifest(
    repo: Path,
    manifest_path: str,
    *,
    expected_pr: int,
    expected_head_sha: str,
) -> dict[str, Any]:
    """Load every manifest artifact through repository-safe paths."""

    resolved_repo = resolve_path(repo, label="repository")
    path, manifest = _load_manifest_json(resolved_repo, manifest_path, "review manifest")
    _, review_schema = _load_manifest_json(
        resolved_repo,
        "schemas/review_result.schema.json",
        "review result schema",
    )
    errors: list[str] = []
    if manifest.get("version") != 1:
        errors.append("review manifest version must be 1")
    if manifest.get("pr") != expected_pr:
        errors.append(f"review manifest pr must match PR {expected_pr}")
    if manifest.get("head_sha") != expected_head_sha:
        errors.append("review manifest head_sha must match the current PR head")
    if not isinstance(manifest.get("human_final_review_required"), bool):
        errors.append("review manifest human_final_review_required must be a boolean")
    lanes = manifest.get("lanes")
    if not isinstance(lanes, list) or not lanes:
        errors.append("review manifest lanes must be a non-empty list")
        lanes = []

    artifacts: list[dict[str, Any]] = []
    artifact_paths_seen: set[str] = set()
    lane_ids: set[str] = set()
    lane_roster: list[dict[str, Any]] = []
    for lane_index, lane in enumerate(lanes):
        label = f"review manifest lanes[{lane_index}]"
        if not isinstance(lane, dict):
            errors.append(f"{label} must be an object")
            continue
        lane_id = lane.get("lane_id")
        producer = lane.get("producer_identity")
        if not _nonempty(lane_id):
            errors.append(f"{label}.lane_id must be a non-empty string")
            continue
        if lane_id in lane_ids:
            errors.append(f"duplicate manifest lane_id: {lane_id}")
        lane_ids.add(str(lane_id))
        if not _nonempty(producer):
            errors.append(f"{label}.producer_identity must be a non-empty string")
            continue
        raw_paths = lane.get("artifact_paths")
        if not isinstance(raw_paths, list) or not raw_paths:
            errors.append(f"{label}.artifact_paths must be a non-empty list")
            continue
        roster_entry = {
            "lane_id": str(lane_id),
            "producer_identity": str(producer),
        }
        if _nonempty(lane.get("successor_of")):
            roster_entry["successor_of"] = str(lane["successor_of"])
        lane_roster.append(roster_entry)
        for artifact_index, raw_artifact_path in enumerate(raw_paths):
            if not _nonempty(raw_artifact_path):
                errors.append(f"{label}.artifact_paths[{artifact_index}] must be non-empty")
                continue
            normalized_path = str(raw_artifact_path).strip()
            if normalized_path in artifact_paths_seen:
                errors.append(f"duplicate review artifact path: {normalized_path}")
                continue
            artifact_paths_seen.add(normalized_path)
            try:
                _, artifact = _load_manifest_json(
                    resolved_repo,
                    normalized_path,
                    f"review artifact {normalized_path}",
                )
            except ReviewSemanticError as exc:
                errors.append(str(exc))
                continue
            try:
                validate_instance(
                    review_schema,
                    artifact,
                    f"review artifact {normalized_path}",
                )
            except SpecRailError as exc:
                errors.append(str(exc))
            result = validate_review_artifact(
                artifact,
                expected_pr=expected_pr,
                expected_lane=str(lane_id),
                expected_producer=str(producer),
            )
            errors.extend(f"{normalized_path}: {item}" for item in result["errors"])
            artifact_copy = dict(artifact)
            artifact_copy["artifact_path"] = normalized_path
            artifacts.append(artifact_copy)

    artifact_ids = [item.get("artifact_id") for item in artifacts if _nonempty(item.get("artifact_id"))]
    if len(artifact_ids) != len(set(artifact_ids)):
        errors.append("review artifact IDs must be unique across the manifest")

    per_lane_head: dict[tuple[Any, Any], list[dict[str, Any]]] = {}
    for artifact in artifacts:
        if artifact.get("status") in TERMINAL_STATUSES:
            key = (artifact.get("reviewer_lane"), artifact.get("head_sha"))
            per_lane_head.setdefault(key, []).append(artifact)
    for (lane_id, head_sha), candidates in per_lane_head.items():
        if len(candidates) > 1:
            errors.append(
                f"duplicate terminal artifacts for lane {lane_id} at head {head_sha}"
            )

    current_head = [
        item for item in artifacts if item.get("head_sha") == expected_head_sha
    ]
    current = [
        item
        for item in current_head
        if item.get("status") in TERMINAL_STATUSES
    ]
    if not current:
        errors.append("review manifest has no terminal artifact for the current head")
    elif len(current) > 1:
        errors.append("review manifest has multiple terminal artifacts for the current head")

    stale_findings: dict[tuple[str, str], dict[str, Any]] = {}
    required_carry: set[tuple[str, str]] = set()
    for artifact in artifacts:
        source_head = artifact.get("head_sha")
        if source_head == expected_head_sha:
            continue
        for finding in artifact.get("findings", []):
            if isinstance(finding, dict) and _nonempty(finding.get("id")) and _nonempty(source_head):
                key = (str(finding["id"]), str(source_head))
                if key in stale_findings and stale_findings[key] != finding:
                    errors.append(f"conflicting stale finding definition: {key[0]} at {key[1]}")
                stale_findings[key] = finding
                required_carry.add(key)
        for finding in artifact.get("prior_findings", []):
            if (
                isinstance(finding, dict)
                and finding.get("status") == "unresolved"
                and _nonempty(finding.get("id"))
                and _nonempty(finding.get("source_head_sha"))
            ):
                required_carry.add(
                    (str(finding["id"]), str(finding["source_head_sha"]))
                )

    carried: dict[tuple[str, str], dict[str, Any]] = {}
    for artifact in current:
        for finding in artifact.get("prior_findings", []):
            if isinstance(finding, dict) and _nonempty(finding.get("id")) and _nonempty(finding.get("source_head_sha")):
                key = (str(finding["id"]), str(finding["source_head_sha"]))
                if key in carried and carried[key] != finding:
                    errors.append(f"conflicting prior finding carry-forward: {key[0]} at {key[1]}")
                carried[key] = finding
    missing_carry = sorted(required_carry - set(carried))
    for finding_id, source_head in missing_carry:
        errors.append(f"missing prior finding carry-forward: {finding_id} from {source_head}")
    extra_carry = sorted(set(carried) - required_carry)
    for finding_id, source_head in extra_carry:
        errors.append(f"prior finding has no manifest source artifact: {finding_id} from {source_head}")

    blockers: list[str] = []
    review_sources: set[str] = set()
    completed_times: list[str] = []
    for artifact in current_head:
        result = validate_review_artifact(artifact, expected_pr=expected_pr, expected_head_sha=expected_head_sha)
        blockers.extend(result["blocking_reasons"])
    for artifact in current:
        if artifact.get("human_final_review_required") != manifest.get(
            "human_final_review_required"
        ):
            errors.append(
                f"current artifact {artifact.get('artifact_id')} conflicts with manifest human_final_review_required"
            )
        if _nonempty(artifact.get("review_source")):
            review_sources.add(str(artifact["review_source"]))
        if _nonempty(artifact.get("review_completed_at")):
            completed_times.append(str(artifact["review_completed_at"]))
    if len(review_sources) > 1:
        blockers.append("current-head artifacts have conflicting review_source values")

    latest_completed_at = None
    latest_completed_time = None
    for value in completed_times:
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            continue
        if latest_completed_time is None or parsed > latest_completed_time:
            latest_completed_time = parsed
            latest_completed_at = value

    raw = path.read_bytes()
    return {
        "manifest_path": path.relative_to(resolved_repo).as_posix(),
        "manifest_sha256": hashlib.sha256(raw).hexdigest(),
        "pr": expected_pr,
        "head_sha": expected_head_sha,
        "review_source": next(iter(review_sources), None),
        "review_completed_at": latest_completed_at,
        "human_final_review_required": manifest.get("human_final_review_required"),
        "lane_roster": lane_roster,
        "artifacts": artifacts,
        "current_artifact_ids": [item.get("artifact_id") for item in current],
        "errors": errors,
        "blocking_reasons": sorted(set(blockers)),
    }


def evaluate_review_evidence(
    evidence: Any,
    *,
    expected_pr: int | None,
    expected_head_sha: str | None,
) -> dict[str, list[str]]:
    """Revalidate embedded manifest evidence inside the offline PR gate."""

    errors: list[str] = []
    blockers: list[str] = []
    satisfied: list[str] = []
    if not isinstance(evidence, dict):
        return {
            "errors": ["review_evidence must be an object"],
            "blocking_reasons": [],
            "satisfied": [],
        }
    if evidence.get("pr") != expected_pr:
        errors.append("review_evidence.pr must match pr")
    if evidence.get("head_sha") != expected_head_sha:
        errors.append("review_evidence.head_sha must match head_sha")
    embedded_errors = evidence.get("errors")
    if not isinstance(embedded_errors, list):
        errors.append("review_evidence.errors must be a list")
    else:
        errors.extend(str(item) for item in embedded_errors if _nonempty(item))
    embedded_blockers = evidence.get("blocking_reasons")
    if not isinstance(embedded_blockers, list):
        errors.append("review_evidence.blocking_reasons must be a list")
    else:
        blockers.extend(str(item) for item in embedded_blockers if _nonempty(item))
    artifacts = evidence.get("artifacts")
    if not isinstance(artifacts, list) or not artifacts:
        errors.append("review_evidence.artifacts must be a non-empty list")
    else:
        current = 0
        for index, artifact in enumerate(artifacts):
            result = validate_review_artifact(artifact, expected_pr=expected_pr)
            errors.extend(f"review_evidence.artifacts[{index}]: {item}" for item in result["errors"])
            if not isinstance(artifact, dict):
                continue
            if artifact.get("head_sha") == expected_head_sha and artifact.get("status") in TERMINAL_STATUSES:
                current += 1
                blockers.extend(result["blocking_reasons"])
        if current == 0:
            errors.append("review_evidence has no current-head terminal artifact")
    if not errors:
        satisfied.append("review manifest and artifacts are semantically valid")
    if not blockers:
        satisfied.append("terminal review evidence has no blocking findings")
    return {
        "errors": sorted(set(errors)),
        "blocking_reasons": sorted(set(blockers)),
        "satisfied": satisfied,
    }

"""Trusted path-derived enforcement classification and approved-spec checks."""

from __future__ import annotations

import fnmatch
import hashlib
import json
import re
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Any

from specrail_lib import (
    PackConfig,
    SpecRailError,
    resolve_path,
    resolve_repo_path,
    spec_packet_artifact_paths,
    validated_repo_relative_path,
)


CLASSIFICATION_SOURCES = {"github_changed_files", "tech_spec"}
APPROVED_SPEC_FIELDS = {
    "repository",
    "issue",
    "spec_paths",
    "content_hashes",
    "spec_revisions",
    "approved_at",
    "maintainer_actor",
    "state_source",
    "state_trusted",
    "default_base_ref",
    "default_base_sha",
}
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
COMMIT_RE = re.compile(r"^[0-9a-fA-F]{40}$")
PLANNED_CHANGES_MANIFEST_RE = re.compile(
    rb"<!--\s*specrail-planned-changes\s*\n(.*?)\n\s*-->", re.DOTALL
)


def sensitive_registry(config: PackConfig) -> dict[str, list[str]]:
    enforcement = config.workflow.get("enforcement", {})
    if not isinstance(enforcement, dict):
        raise SpecRailError("workflow.yaml: enforcement must be a mapping")
    unknown_enforcement = sorted(set(enforcement) - {"sensitive_registry"})
    if unknown_enforcement:
        raise SpecRailError(
            "workflow.yaml: enforcement contains unsupported fields: "
            f"{', '.join(unknown_enforcement)}"
        )
    registry = enforcement.get("sensitive_registry", {})
    if not isinstance(registry, dict):
        raise SpecRailError(
            "workflow.yaml: enforcement.sensitive_registry must be a mapping"
        )
    unknown = sorted(set(registry) - {"paths", "specs"})
    if unknown:
        raise SpecRailError(
            "workflow.yaml: enforcement.sensitive_registry contains unsupported "
            f"fields: {', '.join(unknown)}"
        )

    normalized: dict[str, list[str]] = {"paths": [], "specs": []}
    for key in normalized:
        values = registry.get(key, [])
        if not isinstance(values, list):
            raise SpecRailError(
                f"workflow.yaml: enforcement.sensitive_registry.{key} must be a list"
            )
        for index, raw in enumerate(values, start=1):
            if not isinstance(raw, str) or not raw.strip():
                raise SpecRailError(
                    "workflow.yaml: enforcement.sensitive_registry."
                    f"{key}[{index}] must be a non-empty string"
                )
            pattern = validated_repo_relative_path(
                raw.strip(),
                label=f"workflow.yaml: enforcement.sensitive_registry.{key}[{index}]",
            ).as_posix()
            if pattern in {"", "."}:
                raise SpecRailError(
                    f"workflow.yaml: enforcement.sensitive_registry.{key}[{index}] "
                    "must identify a repository path"
                )
            normalized[key].append(pattern)
    return normalized


def validate_sensitive_registry(config: PackConfig) -> list[str]:
    try:
        sensitive_registry(config)
    except SpecRailError as exc:
        return [str(exc)]
    return []


def _trusted_path(repo: Path, raw: Any, label: str) -> str:
    if not isinstance(raw, str) or not raw.strip():
        raise SpecRailError(f"{label} must be a non-empty string")
    relative = validated_repo_relative_path(raw.strip(), label=label)
    resolved_repo = resolve_path(repo, label="repository")
    resolved = resolve_repo_path(repo, relative, label=label)
    expected = resolved_repo.joinpath(*relative.parts)
    if resolved != expected:
        raise SpecRailError(f"{label} must preserve its repository path identity")
    return relative.as_posix()


def normalize_changed_paths(repo: Path, values: Any, *, label: str) -> list[str]:
    if not isinstance(values, list):
        raise SpecRailError(f"{label} must be a list")
    normalized = [
        _trusted_path(repo, raw, f"{label}[{index}]")
        for index, raw in enumerate(values, start=1)
    ]
    if len(set(normalized)) != len(normalized):
        raise SpecRailError(f"{label} must not contain duplicate normalized paths")
    return sorted(normalized)


def classify_sensitive_changes(
    config: PackConfig,
    repo: Path,
    changed_paths: Any,
    spec_refs: Any,
    *,
    source: str,
) -> dict[str, Any]:
    if source not in CLASSIFICATION_SOURCES:
        raise SpecRailError(
            "sensitive_classification.source must be one of: "
            + ", ".join(sorted(CLASSIFICATION_SOURCES))
        )
    registry = sensitive_registry(config)
    paths = normalize_changed_paths(
        repo, changed_paths, label="sensitive_classification.changed_paths"
    )
    specs = normalize_changed_paths(
        repo, spec_refs, label="sensitive_classification.spec_refs"
    )
    matched_paths = sorted(
        path
        for path in paths
        if any(fnmatch.fnmatchcase(path, pattern) for pattern in registry["paths"])
    )
    matched_specs = sorted(
        path
        for path in specs
        if any(fnmatch.fnmatchcase(path, pattern) for pattern in registry["specs"])
    )
    return {
        "source": source,
        "changed_paths": paths,
        "spec_refs": specs,
        "matched_paths": matched_paths,
        "matched_specs": matched_specs,
        "registry_configured": bool(registry["paths"] or registry["specs"]),
        "enforcement_sensitive": bool(matched_paths or matched_specs),
    }


def _git(repo: Path, args: list[str], label: str) -> bytes:
    completed = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=False,
        capture_output=True,
    )
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", errors="replace").strip()
        raise SpecRailError(f"{label}: {detail or 'git command failed'}")
    return completed.stdout


def _hash_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def trusted_default_base(
    repo: Path, *, default_base_ref: Any, default_base_sha: Any
) -> tuple[str, str]:
    """Revalidate adapter-provided GitHub default-base identity against origin."""

    if not isinstance(default_base_ref, str) or not default_base_ref.strip():
        raise SpecRailError("trusted default base ref must be a non-empty string")
    branch = default_base_ref.strip()
    if branch == "HEAD" or branch.startswith("refs/"):
        raise SpecRailError("trusted default base ref must be an unqualified branch name")
    origin_ref = f"refs/remotes/origin/{branch}"
    check_ref = subprocess.run(
        ["git", "-C", str(repo), "check-ref-format", origin_ref],
        check=False, capture_output=True,
    )
    if check_ref.returncode != 0:
        raise SpecRailError("trusted default base ref is not a valid origin branch")
    if not isinstance(default_base_sha, str) or not COMMIT_RE.fullmatch(default_base_sha):
        raise SpecRailError("trusted default base SHA must be a full commit SHA")
    trusted_sha = default_base_sha.lower()
    local_sha = _git(
        repo, ["rev-parse", "--verify", f"{origin_ref}^{{commit}}"],
        "trusted default base origin ref",
    ).decode("utf-8", errors="strict").strip().lower()
    if local_sha != trusted_sha:
        raise SpecRailError("trusted default base SHA does not match the fetched origin branch")
    symbolic = subprocess.run(
        ["git", "-C", str(repo), "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"],
        check=False, capture_output=True,
    )
    if symbolic.returncode != 0:
        raise SpecRailError(
            "trusted default branch origin/HEAD is missing or is not a symbolic ref"
        )
    symbolic_ref = symbolic.stdout.decode("utf-8", errors="strict").strip()
    if symbolic_ref != origin_ref:
        raise SpecRailError(
            "trusted default branch origin/HEAD does not match the adapter default base"
        )
    return branch, trusted_sha


def approved_spec_source_commits(
    config: PackConfig, repo: Path, issue: int, *,
    default_base_ref: Any, default_base_sha: Any,
) -> dict[str, str]:
    """Return each approved spec path's last source commit on trusted default."""

    _branch, trusted_base_sha = trusted_default_base(
        repo, default_base_ref=default_base_ref, default_base_sha=default_base_sha
    )
    configured = spec_packet_artifact_paths(config, issue, repo=repo)
    result: dict[str, str] = {}
    for path in [configured["product_spec"], configured["tech_spec"]]:
        source_commit = _git(
            repo,
            ["log", "-1", "--format=%H", trusted_base_sha, "--", path],
            f"approved spec source commit {path}",
        ).decode("utf-8", errors="strict").strip()
        if not COMMIT_RE.fullmatch(source_commit):
            raise SpecRailError(f"approved spec lacks a source commit: {path}")
        result[path] = source_commit.lower()
    return result


def build_approved_spec_evidence(
    config: PackConfig,
    repo: Path,
    *,
    repository: str,
    issue: int,
    spec_revisions: dict[str, Any],
    approved_at: str,
    maintainer_actor: str,
    gated_head_sha: str | None = None,
    default_base_ref: Any,
    default_base_sha: Any,
) -> dict[str, Any]:
    paths = spec_packet_artifact_paths(config, issue, repo=repo)
    spec_paths = [paths["product_spec"], paths["tech_spec"]]
    if not isinstance(spec_revisions, dict) or set(spec_revisions) != set(spec_paths):
        raise SpecRailError("spec_revisions must cover every approved spec path")
    hashes: dict[str, str] = {}
    for path in spec_paths:
        revision = spec_revisions[path]
        source_commit = revision.get("source_commit_sha") if isinstance(revision, dict) else None
        if not isinstance(source_commit, str) or not COMMIT_RE.fullmatch(source_commit):
            raise SpecRailError(f"spec_revisions[{path}].source_commit_sha must be a full SHA")
        hashes[path] = _hash_bytes(
            _git(repo, ["show", f"{source_commit}:{path}"], f"approved spec source {path}")
        )
    evidence = {
        "repository": repository,
        "issue": issue,
        "spec_paths": spec_paths,
        "content_hashes": hashes,
        "spec_revisions": spec_revisions,
        "approved_at": approved_at,
        "maintainer_actor": maintainer_actor,
        "state_source": "label",
        "state_trusted": True,
        "default_base_ref": default_base_ref,
        "default_base_sha": default_base_sha,
    }
    validate_approved_spec_evidence(
        config,
        repo,
        evidence,
        repository=repository,
        issue=issue,
        gated_head_sha=gated_head_sha,
    )
    return evidence


def _aware_timestamp(value: Any) -> bool:
    if not isinstance(value, str) or not value.strip():
        return False
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return False
    return parsed.tzinfo is not None


def _timestamp(value: Any, label: str) -> datetime:
    if not isinstance(value, str) or not value.strip():
        raise SpecRailError(f"{label} must be a timezone-aware ISO-8601 timestamp")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise SpecRailError(
            f"{label} must be a timezone-aware ISO-8601 timestamp"
        ) from exc
    if parsed.tzinfo is None:
        raise SpecRailError(f"{label} must be a timezone-aware ISO-8601 timestamp")
    return parsed


def validate_approved_spec_evidence(
    config: PackConfig,
    repo: Path,
    evidence: Any,
    *,
    repository: str,
    issue: int,
    gated_head_sha: str | None = None,
) -> None:
    if not isinstance(evidence, dict):
        raise SpecRailError("approved_spec must be an object")
    unknown = sorted(set(evidence) - APPROVED_SPEC_FIELDS)
    if unknown:
        raise SpecRailError(
            "approved_spec contains unsupported fields: " + ", ".join(unknown)
        )
    if evidence.get("repository") != repository:
        raise SpecRailError("approved_spec.repository must match repository")
    if evidence.get("issue") != issue:
        raise SpecRailError("approved_spec.issue must match linked issue")
    if evidence.get("state_source") != "label" or evidence.get("state_trusted") is not True:
        raise SpecRailError(
            "approved_spec requires state_source=label and state_trusted=true"
        )
    if not isinstance(evidence.get("maintainer_actor"), str) or not evidence["maintainer_actor"].strip():
        raise SpecRailError("approved_spec.maintainer_actor must be a non-empty string")
    if not _aware_timestamp(evidence.get("approved_at")):
        raise SpecRailError(
            "approved_spec.approved_at must be a timezone-aware ISO-8601 timestamp"
        )

    approved_at = _timestamp(evidence.get("approved_at"), "approved_spec.approved_at")
    _trusted_base_ref, trusted_base_sha = trusted_default_base(
        repo,
        default_base_ref=evidence.get("default_base_ref"),
        default_base_sha=evidence.get("default_base_sha"),
    )

    configured = spec_packet_artifact_paths(config, issue, repo=repo)
    expected_paths = [configured["product_spec"], configured["tech_spec"]]
    paths = normalize_changed_paths(
        repo, evidence.get("spec_paths"), label="approved_spec.spec_paths"
    )
    if paths != sorted(expected_paths):
        raise SpecRailError("approved_spec.spec_paths must match configured product and tech specs")
    hashes = evidence.get("content_hashes")
    if not isinstance(hashes, dict) or set(hashes) != set(expected_paths):
        raise SpecRailError("approved_spec.content_hashes must cover every approved spec path")
    revisions = evidence.get("spec_revisions")
    if not isinstance(revisions, dict) or set(revisions) != set(expected_paths):
        raise SpecRailError("approved_spec.spec_revisions must cover every spec path")
    if gated_head_sha is not None and not COMMIT_RE.fullmatch(gated_head_sha):
        raise SpecRailError("gated head SHA must be a full commit SHA")
    for path in expected_paths:
        digest = hashes.get(path)
        if not isinstance(digest, str) or not SHA256_RE.fullmatch(digest):
            raise SpecRailError(f"approved_spec.content_hashes[{path}] must be a sha256 hex digest")
        revision = revisions.get(path)
        required_revision_fields = {
            "source_commit_sha", "pr_number", "merged_at", "merge_commit_sha"
        }
        if not isinstance(revision, dict) or set(revision) != required_revision_fields:
            raise SpecRailError(f"approved_spec.spec_revisions[{path}] is malformed")
        source_commit = revision.get("source_commit_sha")
        merge_commit = revision.get("merge_commit_sha")
        pr_number = revision.get("pr_number")
        if not isinstance(source_commit, str) or not COMMIT_RE.fullmatch(source_commit):
            raise SpecRailError(f"approved_spec.spec_revisions[{path}].source_commit_sha is invalid")
        if not isinstance(merge_commit, str) or not COMMIT_RE.fullmatch(merge_commit):
            raise SpecRailError(f"approved_spec.spec_revisions[{path}].merge_commit_sha is invalid")
        if not isinstance(pr_number, int) or isinstance(pr_number, bool) or pr_number <= 0:
            raise SpecRailError(f"approved_spec.spec_revisions[{path}].pr_number is invalid")
        merged_at = _timestamp(
            revision.get("merged_at"), f"approved_spec.spec_revisions[{path}].merged_at"
        )
        if merged_at > approved_at:
            raise SpecRailError(f"approved spec PR merged after approval: {path}")
        _git(repo, ["cat-file", "-e", f"{merge_commit}^{{commit}}"], f"approved spec merge commit {path}")
        _git(
            repo,
            ["merge-base", "--is-ancestor", merge_commit, trusted_base_sha],
            f"approved spec merge commit must be on trusted default base: {path}",
        )
        source_digest = _hash_bytes(
            _git(repo, ["show", f"{source_commit}:{path}"], f"approved spec source {path}")
        )
        merge_digest = _hash_bytes(
            _git(repo, ["show", f"{merge_commit}:{path}"], f"approved spec merge {path}")
        )
        current_base_digest = _hash_bytes(
            _git(
                repo,
                ["show", f"{trusted_base_sha}:{path}"],
                f"approved spec at current trusted base {path}",
            )
        )
        gated_digest = digest
        if gated_head_sha is not None:
            gated_digest = _hash_bytes(
                _git(repo, ["show", f"{gated_head_sha}:{path}"], f"approved spec at gated head {path}")
            )
        if not all(
            value == digest
            for value in [source_digest, merge_digest, current_base_digest, gated_digest]
        ):
            raise SpecRailError(
                f"approved spec content changed since approval or hash mismatched: {path}"
            )


def parse_planned_changes_manifest(
    content: bytes, *, label: str = "tech spec"
) -> dict[str, Any]:
    matches = PLANNED_CHANGES_MANIFEST_RE.findall(content)
    if len(matches) != 1:
        raise SpecRailError(
            f"{label} must contain exactly one specrail-planned-changes manifest"
        )
    try:
        manifest = json.loads(matches[0])
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SpecRailError(f"{label} manifest must be valid UTF-8 JSON") from exc
    required = {"version", "issue", "complete", "paths", "spec_refs"}
    if not isinstance(manifest, dict) or set(manifest) != required:
        raise SpecRailError(f"{label} manifest has unsupported or missing fields")
    if (
        not isinstance(manifest.get("version"), int)
        or isinstance(manifest.get("version"), bool)
        or not isinstance(manifest.get("issue"), int)
        or isinstance(manifest.get("issue"), bool)
        or manifest["issue"] < 0
        or not isinstance(manifest.get("complete"), bool)
        or not isinstance(manifest.get("paths"), list)
        or not isinstance(manifest.get("spec_refs"), list)
    ):
        raise SpecRailError(f"{label} manifest field types are invalid")
    return manifest


def classification_from_approved_tech(
    config: PackConfig,
    repo: Path,
    *,
    issue: int,
    base_sha: str,
) -> dict[str, Any]:
    if not COMMIT_RE.fullmatch(base_sha):
        raise SpecRailError("tech spec base_sha must be a full commit SHA")
    tech_path = spec_packet_artifact_paths(config, issue, repo=repo)["tech_spec"]
    base_content = _git(
        repo, ["show", f"{base_sha}:{tech_path}"], "trusted approved tech spec"
    )
    manifest = parse_planned_changes_manifest(base_content, label="configured tech.md")
    if manifest.get("version") != 1 or manifest.get("issue") != issue:
        raise SpecRailError("tech spec manifest version/issue binding is invalid")
    if manifest.get("complete") is not True:
        raise SpecRailError("tech spec manifest must declare complete=true")
    if not manifest.get("paths"):
        raise SpecRailError(
            "tech spec manifest paths must be non-empty; "
            "complete=true requires at least one planned path"
        )
    classification = classify_sensitive_changes(
        config,
        repo,
        manifest.get("paths"),
        manifest.get("spec_refs"),
        source="tech_spec",
    )
    classification.update(
        {
            "source_path": tech_path,
            "source_content_hash": _hash_bytes(base_content),
            "source_base_sha": base_sha,
            "planned_paths_complete": True,
        }
    )
    return classification


def evaluate_sensitive_evidence(
    config: PackConfig,
    repo: Path,
    evidence: dict[str, Any],
    *,
    expected_source: str,
    issue: int | None,
    expected_base_ref: str | None = None,
    expected_base_head: str | None = None,
) -> tuple[dict[str, Any] | None, list[str], list[str]]:
    """Return computed classification, satisfied facts, and blocking reasons."""

    reasons: list[str] = []
    satisfied: list[str] = []
    declaration = evidence.get("enforcement_sensitive")
    if declaration is not None and not isinstance(declaration, bool):
        reasons.append("enforcement_sensitive declaration must be a boolean")
    registry = sensitive_registry(config)
    classification_input = evidence.get("sensitive_classification")
    needs_classification = bool(registry["paths"] or registry["specs"])
    classification: dict[str, Any] | None = None
    if classification_input is None:
        if needs_classification:
            reasons.append("configured sensitive registry requires trusted path evidence")
    elif not isinstance(classification_input, dict):
        reasons.append("sensitive_classification must be an object")
    else:
        unknown = sorted(
            set(classification_input)
            - {
                "source", "changed_paths", "spec_refs", "matched_paths",
                "matched_specs", "registry_configured", "enforcement_sensitive",
            }
        )
        if unknown:
            reasons.append(
                "sensitive_classification contains unsupported fields: "
                + ", ".join(unknown)
            )
        try:
            if classification_input.get("source") != expected_source:
                raise SpecRailError(
                    f"sensitive_classification.source must be {expected_source}"
                )
            classification = classify_sensitive_changes(
                config,
                repo,
                classification_input.get("changed_paths"),
                classification_input.get("spec_refs", []),
                source=expected_source,
            )
            if expected_source == "github_changed_files":
                expected_digest = hashlib.sha256(
                    json.dumps(
                        classification["changed_paths"], separators=(",", ":")
                    ).encode("utf-8")
                ).hexdigest()
                if evidence.get("changed_files_count") != len(
                    classification["changed_paths"]
                ):
                    reasons.append(
                        "changed_files_count conflicts with complete path snapshot"
                    )
                if evidence.get("changed_files_sha256") != expected_digest:
                    reasons.append(
                        "changed_files_sha256 conflicts with complete path snapshot"
                    )
            for field in ["matched_paths", "matched_specs", "registry_configured", "enforcement_sensitive"]:
                if field in classification_input and classification_input[field] != classification[field]:
                    reasons.append(
                        f"sensitive_classification.{field} conflicts with trusted registry calculation"
                    )
        except SpecRailError as exc:
            reasons.append(str(exc))

    computed_sensitive = bool(
        classification and classification["enforcement_sensitive"]
    )
    if computed_sensitive and declaration is not True:
        reasons.append(
            "sensitive registry matched but enforcement_sensitive declaration is not true"
        )
    requires_approval = computed_sensitive or declaration is True
    if requires_approval:
        repository = evidence.get("repository")
        trusted_base_ref: str | None = None
        trusted_base_sha: str | None = None
        try:
            trusted_base_ref, trusted_base_sha = trusted_default_base(
                repo,
                default_base_ref=evidence.get("default_base_ref"),
                default_base_sha=evidence.get("default_base_sha"),
            )
        except SpecRailError as exc:
            reasons.append(str(exc))
        if trusted_base_ref is not None and expected_base_ref != trusted_base_ref:
            reasons.append(
                "reported base_ref does not match the trusted origin default branch"
            )
        if trusted_base_sha is not None and expected_base_head != trusted_base_sha:
            reasons.append(
                "reported base_sha does not match the trusted origin default branch"
            )
        if expected_source == "github_changed_files":
            try:
                checkout_head = _git(
                    repo,
                    ["rev-parse", "--verify", "HEAD^{commit}"],
                    "sensitive PR gate checkout head",
                ).decode("utf-8", errors="strict").strip()
            except SpecRailError as exc:
                reasons.append(str(exc))
            else:
                evidence_head = evidence.get("head_sha")
                query_head = evidence.get("gate_query_head_sha")
                if (
                    not isinstance(evidence_head, str)
                    or not COMMIT_RE.fullmatch(evidence_head)
                    or query_head != evidence_head
                    or checkout_head != evidence_head
                ):
                    reasons.append(
                        "sensitive PR gate requires local checkout HEAD, head_sha, "
                        "and gate_query_head_sha to match"
                    )
        if not isinstance(repository, str) or not repository.strip():
            reasons.append("repository is required for enforcement-sensitive evidence")
        elif issue is None:
            reasons.append("linked issue is required for enforcement-sensitive evidence")
        else:
            try:
                validate_approved_spec_evidence(
                    config,
                    repo,
                    evidence.get("approved_spec"),
                    repository=repository.strip(),
                    issue=issue,
                    gated_head_sha=(
                        evidence.get("head_sha")
                        if expected_source == "github_changed_files"
                        else None
                    ),
                )
                satisfied.append("approved spec evidence revalidated")
            except SpecRailError as exc:
                reasons.append(str(exc))
    elif evidence.get("approved_spec") is not None:
        reasons.append("approved_spec was provided without enforcement_sensitive=true")

    if classification:
        satisfied.append(
            "sensitive registry classification: "
            + ("matched" if computed_sensitive else "not matched")
        )
    return classification, satisfied, reasons

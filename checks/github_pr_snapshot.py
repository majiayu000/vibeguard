"""Collect complete, exact-head GitHub PR changed-file snapshots."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from typing import Any, Callable

from github_evidence_common import EvidenceError, json_array, json_object
from sensitive_enforcement import normalize_changed_paths
from specrail_lib import PackConfig, spec_packet_artifact_paths


PR_FILES_QUERY = """
query SpecRailPRFiles(
  $owner: String!, $name: String!, $number: Int!, $cursor: String
) {
  repository(owner: $owner, name: $name) {
    defaultBranchRef { name target { oid } }
    pullRequest(number: $number) {
      headRefOid
      baseRefName
      baseRefOid
      changedFiles
      files(first: 100, after: $cursor) {
        totalCount
        pageInfo { hasNextPage endCursor }
        nodes { path }
      }
    }
  }
}
""".strip()
ENFORCEMENT_DECLARATION_RE = re.compile(
    r"(?im)^\s*enforcement_sensitive\s*:\s*(true|false)\s*$"
)


def enforcement_declaration(body: Any) -> bool | None:
    if not isinstance(body, str):
        return None
    matches = ENFORCEMENT_DECLARATION_RE.findall(body)
    if not matches:
        return None
    normalized = {value.lower() == "true" for value in matches}
    if len(normalized) != 1:
        raise EvidenceError("PR body contains conflicting enforcement_sensitive declarations")
    return normalized.pop()


def derive_spec_refs(
    config: PackConfig,
    repo: Path,
    linked_issue: int | None,
    changed_paths: Any,
) -> list[str]:
    paths = normalize_changed_paths(
        repo, changed_paths, label="PR changed-file snapshot paths"
    )
    refs = {
        path for path in paths if re.fullmatch(r"specs/GH[1-9][0-9]*/.+", path)
    }
    if linked_issue is not None:
        configured = spec_packet_artifact_paths(config, linked_issue, repo=repo)
        refs.update([configured["product_spec"], configured["tech_spec"]])
    return sorted(refs)


def _mapping(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise EvidenceError(f"{label} must be an object")
    return value


def _string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise EvidenceError(f"{label} must be a non-empty string")
    return value.strip()


def _count(value: Any, label: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise EvidenceError(f"{label} must be a non-negative integer")
    return value


def collect_pr_file_snapshot(
    owner: str,
    name: str,
    pr_number: int,
    run_json: Callable[[list[str]], Any],
    run_array_json: Callable[[list[str]], Any] | None = None,
) -> dict[str, Any]:
    cursor: str | None = None
    identity: tuple[str, str, str, str, str] | None = None
    expected_count: int | None = None
    paths: list[str] = []
    seen_cursors: set[str] = set()

    for _page_number in range(1, 1001):
        args = [
            "api", "graphql", "-F", f"owner={owner}", "-F", f"name={name}",
            "-F", f"number={pr_number}", "-f", f"query={PR_FILES_QUERY}",
        ]
        if cursor is not None:
            args[2:2] = ["-F", f"cursor={cursor}"]
        payload = json_object(run_json(args), "PR files GraphQL response")
        try:
            repository = _mapping(payload["data"]["repository"], "repository")
            pull_request = _mapping(repository["pullRequest"], "pullRequest")
            default_branch = _mapping(
                repository["defaultBranchRef"], "defaultBranchRef"
            )
            default_target = _mapping(
                default_branch["target"], "defaultBranchRef.target"
            )
            files = _mapping(pull_request["files"], "pullRequest.files")
            page_info = _mapping(files["pageInfo"], "pullRequest.files.pageInfo")
            nodes = files["nodes"]
        except (KeyError, TypeError) as exc:
            raise EvidenceError("PR files query returned malformed evidence") from exc
        if not isinstance(nodes, list):
            raise EvidenceError("pullRequest.files.nodes must be a list")

        page_identity = (
            _string(pull_request.get("headRefOid"), "pullRequest.headRefOid"),
            _string(pull_request.get("baseRefName"), "pullRequest.baseRefName"),
            _string(pull_request.get("baseRefOid"), "pullRequest.baseRefOid"),
            _string(default_branch.get("name"), "defaultBranchRef.name"),
            _string(default_target.get("oid"), "defaultBranchRef.target.oid"),
        )
        page_count = _count(files.get("totalCount"), "pullRequest.files.totalCount")
        changed_files = _count(
            pull_request.get("changedFiles"), "pullRequest.changedFiles"
        )
        if page_count != changed_files:
            raise EvidenceError(
                "PR changedFiles and files.totalCount disagree; snapshot is incomplete"
            )
        if identity is None:
            identity = page_identity
            expected_count = page_count
        elif page_identity != identity or page_count != expected_count:
            raise EvidenceError("PR file snapshot drifted during pagination")

        for index, node in enumerate(nodes, start=1):
            item = _mapping(node, f"pullRequest.files.nodes[{index}]")
            paths.append(_string(item.get("path"), f"files.nodes[{index}].path"))

        has_next = page_info.get("hasNextPage")
        if not isinstance(has_next, bool):
            raise EvidenceError("pullRequest.files.pageInfo.hasNextPage must be boolean")
        end_cursor = page_info.get("endCursor")
        if not has_next:
            break
        cursor = _string(end_cursor, "pullRequest.files.pageInfo.endCursor")
        if cursor in seen_cursors:
            raise EvidenceError("PR files pagination cursor did not advance")
        seen_cursors.add(cursor)
    else:
        raise EvidenceError("PR files pagination exceeded 1000 pages")

    assert identity is not None and expected_count is not None
    if len(paths) != expected_count:
        raise EvidenceError(
            f"PR files snapshot incomplete: collected {len(paths)} of {expected_count}"
        )
    if len(set(paths)) != len(paths):
        raise EvidenceError("PR files snapshot contains duplicate paths")
    normalized_paths = sorted(paths)
    all_paths = set(normalized_paths)
    if run_array_json is not None:
        rest_files: list[Any] = []
        for page in range(1, 1001):
            response = json_array(
                run_array_json([
                    "api", "--method", "GET",
                    f"repos/{owner}/{name}/pulls/{pr_number}/files",
                    "-F", "per_page=100", "-F", f"page={page}",
                ]),
                "pull files REST response",
            )
            rest_files.extend(response)
            if len(rest_files) >= expected_count or len(response) < 100:
                break
        else:
            raise EvidenceError("pull files REST pagination exceeded 1000 pages")
        if len(rest_files) != expected_count:
            raise EvidenceError(
                f"pull files REST snapshot incomplete: collected {len(rest_files)} of {expected_count}"
            )
        rest_current: set[str] = set()
        for index, raw in enumerate(rest_files, start=1):
            item = json_object(raw, f"pull files[{index}]")
            filename = _string(item.get("filename"), f"pull files[{index}].filename")
            rest_current.add(filename)
            previous = item.get("previous_filename")
            if previous is not None:
                all_paths.add(_string(previous, f"pull files[{index}].previous_filename"))
            all_paths.add(filename)
        if rest_current != set(normalized_paths):
            raise EvidenceError("GraphQL and REST pull file snapshots disagree")
    normalized_paths = sorted(all_paths)
    digest = hashlib.sha256(
        json.dumps(normalized_paths, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    head_sha, base_ref, base_sha, default_base_ref, default_base_sha = identity
    if base_ref != default_base_ref or base_sha != default_base_sha:
        raise EvidenceError(
            "PR base must match the trusted default-branch snapshot"
        )
    return {
        "head_sha": head_sha,
        "base_ref": base_ref,
        "base_sha": base_sha,
        "default_base_ref": default_base_ref,
        "default_base_sha": default_base_sha,
        "file_count": expected_count,
        "path_count": len(normalized_paths),
        "paths": normalized_paths,
        "paths_sha256": digest,
    }


def assert_same_pr_file_snapshot(
    before: dict[str, Any], after: dict[str, Any]
) -> None:
    if before != after:
        raise EvidenceError(
            "PR head, base, or complete changed-file snapshot drifted during gate query"
        )

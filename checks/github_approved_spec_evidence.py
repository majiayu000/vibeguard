"""Collect maintainer-controlled approved-spec label evidence from GitHub."""

from __future__ import annotations

import re
from datetime import datetime
from typing import Any, Callable

from github_evidence_common import EvidenceError, json_array, json_object


APPROVAL_QUERY = """
query SpecRailApprovalLabels(
  $owner: String!, $name: String!, $number: Int!, $cursor: String
) {
  repository(owner: $owner, name: $name) {
    defaultBranchRef { name target { oid } }
    issue(number: $number) {
      state
      labels(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes { name }
      }
    }
  }
}
""".strip()

DEFAULT_BASE_QUERY = """
query SpecRailDefaultBase($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    defaultBranchRef { name target { oid } }
  }
}
""".strip()

APPROVAL_TIMELINE_QUERY = """
query SpecRailApprovalTimeline(
  $owner: String!, $name: String!, $number: Int!, $cursor: String
) {
  repository(owner: $owner, name: $name) {
    defaultBranchRef { name target { oid } }
    issue(number: $number) {
      state
      timelineItems(first: 100, after: $cursor, itemTypes: [LABELED_EVENT]) {
        pageInfo { hasNextPage endCursor }
        nodes {
          ... on LabeledEvent {
            createdAt
            actor { login }
            label { name }
          }
        }
      }
    }
  }
}
""".strip()


def collect_default_base_identity(
    github_repo: str,
    run_json: Callable[[list[str]], Any],
) -> tuple[str, str]:
    owner, name = github_repo.split("/", 1)
    payload = json_object(
        run_json(
            [
                "api", "graphql", "-F", f"owner={owner}", "-F", f"name={name}",
                "-f", f"query={DEFAULT_BASE_QUERY}",
            ]
        ),
        "default-base GraphQL response",
    )
    try:
        repository = json_object(payload["data"]["repository"], "repository")
        default_branch_ref = json_object(
            repository["defaultBranchRef"], "defaultBranchRef"
        )
        default_branch = default_branch_ref["name"]
        default_base_sha = json_object(
            default_branch_ref["target"], "defaultBranchRef.target"
        )["oid"]
    except (KeyError, TypeError) as exc:
        raise EvidenceError("default-base query returned malformed evidence") from exc
    if not isinstance(default_branch, str) or not default_branch.strip():
        raise EvidenceError("default-base query lacks a trusted default branch")
    if not isinstance(default_base_sha, str) or not re.fullmatch(
        r"[0-9a-fA-F]{40}", default_base_sha
    ):
        raise EvidenceError("default-base query lacks a trusted default base SHA")
    return default_branch.strip(), default_base_sha.lower()


def collect_approval_metadata(
    github_repo: str,
    issue: int,
    run_json: Callable[[list[str]], Any],
    *,
    spec_source_commits: dict[str, str] | None = None,
    spec_source_commits_provider: Callable[[str, str], dict[str, str]] | None = None,
) -> dict[str, Any]:
    if spec_source_commits is not None and spec_source_commits_provider is not None:
        raise EvidenceError(
            "provide spec_source_commits or spec_source_commits_provider, not both"
        )
    owner, name = github_repo.split("/", 1)
    identity: tuple[str, str, str] | None = None

    def collect_connection(query: str, key: str) -> list[Any]:
        nonlocal identity
        cursor: str | None = None
        seen_cursors: set[str] = set()
        collected: list[Any] = []
        for _page in range(1000):
            args = [
                "api", "graphql", "-F", f"owner={owner}", "-F", f"name={name}",
                "-F", f"number={issue}", "-f", f"query={query}",
            ]
            if cursor is not None:
                args[2:2] = ["-F", f"cursor={cursor}"]
            payload = json_object(run_json(args), "approved-spec GraphQL response")
            try:
                repository = json_object(payload["data"]["repository"], "repository")
                issue_data = json_object(repository["issue"], "issue")
                default_branch_ref = json_object(
                    repository["defaultBranchRef"], "defaultBranchRef"
                )
                default_branch = default_branch_ref["name"]
                default_base_sha = json_object(
                    default_branch_ref["target"], "defaultBranchRef.target"
                )["oid"]
                connection = json_object(issue_data[key], key)
                nodes = json_array(connection["nodes"], f"{key}.nodes")
                page_info = json_object(connection["pageInfo"], f"{key}.pageInfo")
            except (KeyError, TypeError) as exc:
                raise EvidenceError("approved-spec query returned malformed issue evidence") from exc
            if not isinstance(default_branch, str) or not default_branch.strip():
                raise EvidenceError("approved-spec query lacks a trusted default branch")
            if not isinstance(default_base_sha, str) or not re.fullmatch(
                r"[0-9a-fA-F]{40}", default_base_sha
            ):
                raise EvidenceError("approved-spec query lacks a trusted default base SHA")
            page_identity = (
                default_branch.strip(), default_base_sha.lower(),
                str(issue_data.get("state")),
            )
            if identity is None:
                identity = page_identity
            elif identity != page_identity:
                raise EvidenceError("approved-spec issue evidence drifted during pagination")
            collected.extend(nodes)
            has_next = page_info.get("hasNextPage")
            end_cursor = page_info.get("endCursor")
            if not isinstance(has_next, bool):
                raise EvidenceError(f"approved-spec {key} pageInfo is incomplete")
            if not has_next:
                return collected
            if not isinstance(end_cursor, str) or not end_cursor.strip() or end_cursor in seen_cursors:
                raise EvidenceError(f"approved-spec {key} pagination cursor is invalid")
            seen_cursors.add(end_cursor)
            cursor = end_cursor
        raise EvidenceError(f"approved-spec {key} pagination exceeded 1000 pages")

    labels = collect_connection(APPROVAL_QUERY, "labels")
    events = collect_connection(APPROVAL_TIMELINE_QUERY, "timelineItems")
    assert identity is not None
    default_branch, default_base_sha, issue_state = identity
    if issue_state != "OPEN":
        raise EvidenceError("approved-spec issue must remain OPEN")
    current_labels = {
        item.get("name") for item in labels
        if isinstance(item, dict) and isinstance(item.get("name"), str)
    }
    if "ready_to_implement" not in current_labels:
        raise EvidenceError(
            "approved spec requires current ready_to_implement maintainer label"
        )
    candidates: list[tuple[datetime, dict[str, Any]]] = []
    for event in events:
        if not isinstance(event, dict):
            continue
        label = event.get("label")
        if not isinstance(label, dict) or label.get("name") != "ready_to_implement":
            continue
        created_at = event.get("createdAt")
        if not isinstance(created_at, str) or not created_at.strip():
            raise EvidenceError(
                "ready_to_implement label lacks maintainer actor/timestamp evidence"
            )
        try:
            created_time = datetime.fromisoformat(created_at.replace("Z", "+00:00"))
        except ValueError as exc:
            raise EvidenceError(
                "ready_to_implement label timestamp is invalid"
            ) from exc
        if created_time.tzinfo is None:
            raise EvidenceError(
                "ready_to_implement label timestamp must include timezone"
            )
        candidates.append((created_time, event))
    if not candidates:
        raise EvidenceError(
            "ready_to_implement label lacks maintainer actor/timestamp evidence"
        )
    _approved_time, latest_event = max(candidates, key=lambda item: item[0])
    actor = latest_event.get("actor")
    maintainer_actor = actor.get("login") if isinstance(actor, dict) else None
    approved_at = latest_event["createdAt"].strip()
    if not isinstance(maintainer_actor, str) or not maintainer_actor.strip():
        raise EvidenceError(
            "ready_to_implement label lacks maintainer actor/timestamp evidence"
        )
    maintainer_actor = maintainer_actor.strip()
    result: dict[str, Any] = {
        "approved_at": approved_at,
        "maintainer_actor": maintainer_actor,
        "state_source": "label",
        "state_trusted": True,
        "default_base_ref": default_branch,
        "default_base_sha": default_base_sha,
    }
    if spec_source_commits_provider is not None:
        spec_source_commits = spec_source_commits_provider(
            default_branch, default_base_sha
        )
    if spec_source_commits is None:
        return result
    try:
        approved_time = datetime.fromisoformat(approved_at.replace("Z", "+00:00"))
    except ValueError as exc:
        raise EvidenceError("ready_to_implement label timestamp is invalid") from exc
    if approved_time.tzinfo is None:
        raise EvidenceError("ready_to_implement label timestamp must include timezone")
    revisions: dict[str, Any] = {}
    for path, source_commit in spec_source_commits.items():
        if not re.fullmatch(r"[0-9a-fA-F]{40}", source_commit):
            raise EvidenceError(f"approved spec source commit is invalid: {path}")
        pulls = json_array(run_json(
            [
                "api", "--method", "GET",
                f"repos/{owner}/{name}/commits/{source_commit}/pulls",
            ]
        ), f"associated PR response for {path}")
        candidates: list[dict[str, Any]] = []
        for pull in pulls:
            if not isinstance(pull, dict):
                continue
            base = pull.get("base")
            merged_at = pull.get("merged_at")
            merge_commit = pull.get("merge_commit_sha")
            number = pull.get("number")
            if not isinstance(base, dict) or base.get("ref") != default_branch:
                continue
            if not isinstance(merged_at, str) or not isinstance(merge_commit, str):
                continue
            if not isinstance(number, int) or isinstance(number, bool) or number <= 0:
                continue
            try:
                merged_time = datetime.fromisoformat(merged_at.replace("Z", "+00:00"))
            except ValueError:
                continue
            if merged_time.tzinfo is None or merged_time > approved_time:
                continue
            if not re.fullmatch(r"[0-9a-fA-F]{40}", merge_commit):
                continue
            candidates.append(pull)
        if len(candidates) != 1:
            raise EvidenceError(
                f"approved spec source must have exactly one merged default-branch PR: {path}"
            )
        pull = candidates[0]
        revisions[path] = {
            "source_commit_sha": source_commit.lower(),
            "pr_number": pull["number"],
            "merged_at": pull["merged_at"],
            "merge_commit_sha": pull["merge_commit_sha"].lower(),
        }
    result["spec_revisions"] = revisions
    return result

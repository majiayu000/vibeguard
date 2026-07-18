"""Collect and normalize complete GitHub pull-request review threads."""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from github_evidence_common import EvidenceError


RunGhJson = Callable[[list[str]], dict[str, Any]]

REVIEW_THREADS_QUERY = """
query SpecRailReviewThreads(
  $owner: String!
  $name: String!
  $number: Int!
  $cursor: String
) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $cursor) {
        totalCount
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          id
          isResolved
          isOutdated
          resolvedBy {
            login
          }
          comments(first: 5) {
            nodes {
              url
              author {
                login
              }
            }
          }
        }
      }
    }
  }
}
""".strip()


def _require_mapping(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise EvidenceError(f"{field} must be an object")
    return value


def _require_list(value: Any, field: str) -> list[Any]:
    if not isinstance(value, list):
        raise EvidenceError(f"{field} must be a list")
    return value


def _validated_review_thread_ids(nodes: list[Any]) -> list[str]:
    thread_ids: list[str] = []
    seen: set[str] = set()
    for index, item in enumerate(nodes, start=1):
        if not isinstance(item, dict):
            raise EvidenceError(f"review thread item #{index} must be an object")
        thread_id = item.get("id")
        if not isinstance(thread_id, str) or not thread_id.strip():
            raise EvidenceError(
                f"review thread item #{index} id must be a non-empty string"
            )
        normalized_id = thread_id.strip()
        if normalized_id in seen:
            raise EvidenceError(f"duplicate review thread id: {normalized_id}")
        seen.add(normalized_id)
        thread_ids.append(normalized_id)
    return thread_ids


def _review_thread_page(
    graphql_payload: dict[str, Any],
) -> tuple[list[Any], int, bool, str | None]:
    data = _require_mapping(graphql_payload.get("data"), "data")
    repository = _require_mapping(data.get("repository"), "data.repository")
    pull_request = _require_mapping(
        repository.get("pullRequest"), "data.repository.pullRequest"
    )
    review_threads = _require_mapping(
        pull_request.get("reviewThreads"),
        "data.repository.pullRequest.reviewThreads",
    )
    nodes = _require_list(
        review_threads.get("nodes"),
        "data.repository.pullRequest.reviewThreads.nodes",
    )
    _validated_review_thread_ids(nodes)
    total_count = review_threads.get("totalCount")
    if (
        not isinstance(total_count, int)
        or isinstance(total_count, bool)
        or total_count < 0
    ):
        raise EvidenceError(
            "data.repository.pullRequest.reviewThreads.totalCount "
            "must be a non-negative integer"
        )
    page_info = _require_mapping(
        review_threads.get("pageInfo"),
        "data.repository.pullRequest.reviewThreads.pageInfo",
    )
    has_next_page = page_info.get("hasNextPage")
    if not isinstance(has_next_page, bool):
        raise EvidenceError(
            "data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage "
            "must be a boolean"
        )
    end_cursor = page_info.get("endCursor")
    if has_next_page and (
        not isinstance(end_cursor, str) or not end_cursor.strip()
    ):
        raise EvidenceError(
            "data.repository.pullRequest.reviewThreads.pageInfo.endCursor "
            "must be a non-empty string when hasNextPage is true"
        )
    normalized_cursor = end_cursor.strip() if isinstance(end_cursor, str) else None
    return nodes, total_count, has_next_page, normalized_cursor


def collect_review_threads(
    owner: str,
    name: str,
    pr_number: int,
    run_gh_json: RunGhJson,
) -> dict[str, Any]:
    nodes: list[Any] = []
    expected_total: int | None = None
    cursor: str | None = None
    seen_cursors: set[str] = set()
    seen_thread_ids: set[str] = set()

    while True:
        query_args = [
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
        if cursor is not None:
            query_args.extend(["-F", f"cursor={cursor}"])

        payload = run_gh_json(query_args)
        page_nodes, total_count, has_next_page, end_cursor = (
            _review_thread_page(payload)
        )
        if expected_total is None:
            expected_total = total_count
        elif total_count != expected_total:
            raise EvidenceError(
                "review thread totalCount changed while collecting pages; "
                "rerun PR evidence collection"
            )
        for thread_id in _validated_review_thread_ids(page_nodes):
            if thread_id in seen_thread_ids:
                raise EvidenceError(
                    "review thread pagination repeated thread id "
                    f"{thread_id}; rerun PR evidence collection"
                )
            seen_thread_ids.add(thread_id)
        nodes.extend(page_nodes)
        if len(nodes) > expected_total:
            raise EvidenceError(
                "review thread pagination returned more nodes than totalCount"
            )

        if not has_next_page:
            if len(nodes) != expected_total:
                raise EvidenceError(
                    "review thread pagination ended before totalCount was collected"
                )
            if len(seen_thread_ids) != expected_total:
                raise EvidenceError(
                    "review thread distinct id count does not match totalCount"
                )
            return {
                "data": {
                    "repository": {
                        "pullRequest": {
                            "reviewThreads": {
                                "nodes": nodes,
                                "totalCount": expected_total,
                                "pageInfo": {
                                    "hasNextPage": False,
                                    "endCursor": end_cursor,
                                },
                            }
                        }
                    }
                }
            }

        if not page_nodes:
            raise EvidenceError(
                "review thread pagination made no progress while hasNextPage is true"
            )
        if end_cursor in seen_cursors:
            raise EvidenceError(
                "review thread pagination repeated an endCursor; "
                "rerun PR evidence collection"
            )
        seen_cursors.add(end_cursor)
        cursor = end_cursor


def _first_comment_url(thread: dict[str, Any]) -> str | None:
    comments = thread.get("comments")
    if not isinstance(comments, dict):
        return None
    nodes = comments.get("nodes")
    if not isinstance(nodes, list):
        return None
    for node in nodes:
        if (
            isinstance(node, dict)
            and isinstance(node.get("url"), str)
            and node["url"].strip()
        ):
            return node["url"].strip()
    return None


def _resolver_login(thread: dict[str, Any]) -> str | None:
    for key in ["resolvedBy", "resolved_by"]:
        value = thread.get(key)
        if (
            isinstance(value, dict)
            and isinstance(value.get("login"), str)
            and value["login"].strip()
        ):
            return value["login"].strip()
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def _resolver_role(thread: dict[str, Any]) -> str | None:
    for key in ["resolverRole", "resolver_role"]:
        value = thread.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def normalize_review_threads(
    graphql_payload: dict[str, Any],
    resolver_roles: dict[str, str] | None = None,
) -> list[dict[str, Any]]:
    nodes, total_count, has_next_page, _ = _review_thread_page(graphql_payload)
    if has_next_page:
        raise EvidenceError(
            "review thread evidence is incomplete because hasNextPage is true"
        )
    if len(nodes) != total_count:
        raise EvidenceError(
            "review thread evidence node count does not match totalCount"
        )

    normalized: list[dict[str, Any]] = []
    for item in nodes:
        thread: dict[str, Any] = {
            "id": item["id"].strip(),
            "is_resolved": item.get("isResolved") is True,
            "is_outdated": item.get("isOutdated") is True,
        }
        url = _first_comment_url(item)
        if url:
            thread["url"] = url
        resolver = _resolver_login(item)
        if resolver:
            thread["resolved_by"] = resolver
        role = _resolver_role(item)
        if not role and resolver and resolver_roles:
            role = resolver_roles.get(resolver)
        if role:
            thread["resolver_role"] = role
        normalized.append(thread)
    return normalized

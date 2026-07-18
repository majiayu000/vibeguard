"""Review-thread, authorization, and reviewer-lane evidence helpers."""

from __future__ import annotations

import json
from typing import Any

from github_evidence_common import EvidenceError


LANE_FAILURE_KINDS = {"usage_limit", "crash", "zero_output", "closed", "other"}
THREAD_ROLE_PREFIX = "thread:"


def _read_json_file(path: str, field: str) -> Any:
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except OSError as exc:
        raise EvidenceError(f"cannot read {field} file {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise EvidenceError(f"{field} file is not valid JSON: {exc.msg}") from exc


def _require_mapping(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise EvidenceError(f"{field} must be an object")
    return value


def _require_list(value: Any, field: str) -> list[Any]:
    if not isinstance(value, list):
        raise EvidenceError(f"{field} must be a list")
    return value


def _first_comment_url(thread: dict[str, Any]) -> str | None:
    comments = thread.get("comments")
    if not isinstance(comments, dict) or not isinstance(comments.get("nodes"), list):
        return None
    for node in comments["nodes"]:
        if isinstance(node, dict) and isinstance(node.get("url"), str) and node["url"].strip():
            return node["url"].strip()
    return None


def _first_comment_identity(thread: dict[str, Any], index: int) -> tuple[str, str]:
    comments = thread.get("comments")
    if not isinstance(comments, dict) or not isinstance(comments.get("nodes"), list):
        raise EvidenceError(f"review thread item #{index} requires root comment evidence")
    nodes = comments["nodes"]
    if not nodes or not isinstance(nodes[0], dict):
        raise EvidenceError(f"review thread item #{index} requires a root comment")
    root = nodes[0]
    comment_id = root.get("id")
    author = root.get("author")
    if not isinstance(comment_id, str) or not comment_id.strip():
        raise EvidenceError(f"review thread item #{index} root comment requires id")
    if (
        not isinstance(author, dict)
        or not isinstance(author.get("login"), str)
        or not author["login"].strip()
    ):
        raise EvidenceError(f"review thread item #{index} root comment requires author.login")
    return comment_id.strip(), author["login"].strip()


def _resolver_login(thread: dict[str, Any]) -> str | None:
    for key in ["resolvedBy", "resolved_by"]:
        value = thread.get(key)
        if isinstance(value, dict) and isinstance(value.get("login"), str) and value["login"].strip():
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


def _normalize_resolver_entry(value: Any, label: str) -> dict[str, Any]:
    if isinstance(value, str) and value.strip():
        return {"resolver_role": value.strip()}
    if not isinstance(value, dict):
        raise EvidenceError(f"{label} must be a role string or object")
    role = value.get("resolver_role") or value.get("role")
    if not isinstance(role, str) or not role.strip():
        raise EvidenceError(f"{label}.resolver_role must be a non-empty string")
    normalized: dict[str, Any] = {"resolver_role": role.strip()}
    for key in ["lane_id", "successor_of", "re_review_artifact_id"]:
        item = value.get(key)
        if isinstance(item, str) and item.strip():
            normalized[key] = item.strip()
    if "authorized_human_maintainer" in value:
        if not isinstance(value["authorized_human_maintainer"], bool):
            raise EvidenceError(f"{label}.authorized_human_maintainer must be a boolean")
        normalized["authorized_human_maintainer"] = value["authorized_human_maintainer"]
    return normalized


def _resolver_role_map(payload: Any) -> dict[str, dict[str, Any]]:
    source = payload
    if isinstance(payload, dict):
        if isinstance(payload.get("resolver_roles"), dict):
            source = payload["resolver_roles"]
        elif isinstance(payload.get("lane_roster"), list):
            source = payload["lane_roster"]
        elif isinstance(payload.get("lanes"), list):
            source = payload["lanes"]

    roles: dict[str, dict[str, Any]] = {}
    if isinstance(source, dict):
        for login, value in source.items():
            if not isinstance(login, str) or not login.strip():
                raise EvidenceError("resolver role map login must be a non-empty string")
            roles[login.strip()] = _normalize_resolver_entry(
                value, f"resolver role map {login.strip()}"
            )
        _add_thread_resolver_roles(payload, roles)
        return roles

    if isinstance(source, list):
        for index, lane in enumerate(source, start=1):
            if not isinstance(lane, dict):
                raise EvidenceError(f"resolver role lane_roster item #{index} must be an object")
            login = lane.get("login") or lane.get("github_login") or lane.get("actor") or lane.get("resolved_by")
            if not isinstance(login, str) or not login.strip():
                raise EvidenceError(f"resolver role lane_roster item #{index} requires login")
            roles[login.strip()] = _normalize_resolver_entry(
                lane, f"resolver role lane_roster item #{index}"
            )
        _add_thread_resolver_roles(payload, roles)
        return roles
    raise EvidenceError("resolver role map must be an object or lane roster list")


def _add_thread_resolver_roles(
    payload: Any,
    roles: dict[str, dict[str, Any]],
) -> None:
    if not isinstance(payload, dict) or "thread_resolver_roles" not in payload:
        return
    thread_roles = payload["thread_resolver_roles"]
    if not isinstance(thread_roles, dict):
        raise EvidenceError("thread_resolver_roles must be an object")
    for thread_id, value in thread_roles.items():
        if not isinstance(thread_id, str) or not thread_id.strip():
            raise EvidenceError(
                "thread_resolver_roles thread id must be a non-empty string"
            )
        normalized_id = thread_id.strip()
        if not isinstance(value, dict):
            raise EvidenceError(
                f"thread_resolver_roles {normalized_id} must be an object"
            )
        resolver_login = value.get("resolver_login")
        if not isinstance(resolver_login, str) or not resolver_login.strip():
            raise EvidenceError(
                f"thread_resolver_roles {normalized_id}.resolver_login "
                "must be a non-empty string"
            )
        normalized = _normalize_resolver_entry(
            value,
            f"thread_resolver_roles {normalized_id}",
        )
        normalized["resolver_login"] = resolver_login.strip()
        roles[f"{THREAD_ROLE_PREFIX}{normalized_id}"] = normalized


def load_resolver_role_map(path: str | None) -> dict[str, dict[str, Any]]:
    if path is None:
        return {}
    return _resolver_role_map(_read_json_file(path, "resolver role map"))


def normalize_review_threads(
    graphql_payload: dict[str, Any],
    resolver_roles: dict[str, dict[str, Any]] | dict[str, str] | None = None,
) -> list[dict[str, Any]]:
    data = _require_mapping(graphql_payload.get("data"), "data")
    repository = _require_mapping(data.get("repository"), "data.repository")
    pull_request = _require_mapping(repository.get("pullRequest"), "data.repository.pullRequest")
    review_threads = _require_mapping(
        pull_request.get("reviewThreads"), "data.repository.pullRequest.reviewThreads"
    )
    nodes = _require_list(
        review_threads.get("nodes"), "data.repository.pullRequest.reviewThreads.nodes"
    )

    normalized: list[dict[str, Any]] = []
    for index, item in enumerate(nodes, start=1):
        if not isinstance(item, dict):
            raise EvidenceError(f"review thread item #{index} must be an object")
        thread: dict[str, Any] = {
            "is_resolved": item.get("isResolved") is True,
            "is_outdated": item.get("isOutdated") is True,
            "actionable": item.get("actionable") is not False,
        }
        thread_id = item.get("id")
        if isinstance(thread_id, str) and thread_id.strip():
            thread["id"] = thread_id.strip()
        url = _first_comment_url(item)
        if url:
            thread["url"] = url
        original_comment_id, original_author = _first_comment_identity(item, index)
        thread["original_comment_id"] = original_comment_id
        thread["original_author"] = original_author
        resolver = _resolver_login(item)
        if resolver:
            thread["resolved_by"] = resolver
        role = _resolver_role(item)
        metadata: dict[str, Any] = {}
        if resolver and resolver_roles:
            raw_metadata = None
            if isinstance(thread_id, str) and thread_id.strip():
                thread_metadata = resolver_roles.get(
                    f"{THREAD_ROLE_PREFIX}{thread_id.strip()}"
                )
                if (
                    isinstance(thread_metadata, dict)
                    and thread_metadata.get("resolver_login") == resolver
                ):
                    raw_metadata = thread_metadata
            if raw_metadata is None:
                raw_metadata = resolver_roles.get(resolver)
        else:
            raw_metadata = None
        if raw_metadata is not None:
            metadata = (
                {"resolver_role": raw_metadata}
                if isinstance(raw_metadata, str)
                else dict(raw_metadata)
            )
            if not role:
                role = metadata.get("resolver_role")
        if role:
            thread["resolver_role"] = role
        for key in [
            "lane_id",
            "successor_of",
            "re_review_artifact_id",
            "authorized_human_maintainer",
        ]:
            if key in metadata:
                thread[key] = metadata[key]
        normalized.append(thread)
    return normalized


def build_human_authorization(
    actor: str | None,
    source: str | None,
    summary: str | None,
) -> dict[str, str] | None:
    provided = [value for value in [actor, source, summary] if value is not None and value.strip()]
    if not provided:
        return None
    if not actor or not actor.strip() or not source or not source.strip():
        raise EvidenceError(
            "--authorization-actor and --authorization-source must be provided together"
        )
    authorization = {"actor": actor.strip(), "source": source.strip()}
    if summary and summary.strip():
        authorization["summary"] = summary.strip()
    return authorization


def build_self_review_authorization(
    actor: str | None,
    source: str | None,
    scope: str | None,
    summary: str | None,
) -> dict[str, str] | None:
    provided = [
        value for value in [actor, source, scope, summary]
        if value is not None and value.strip()
    ]
    if not provided:
        return None
    if not actor or not actor.strip() or not source or not source.strip() or not scope or not scope.strip():
        raise EvidenceError(
            "--self-review-authorization-actor, --self-review-authorization-source, "
            "and --self-review-authorization-scope must be provided together"
        )
    authorization = {"actor": actor.strip(), "source": source.strip(), "scope": scope.strip()}
    if summary and summary.strip():
        authorization["summary"] = summary.strip()
    return authorization


def _normalize_lane_failure(item: Any, index: int) -> dict[str, Any]:
    if not isinstance(item, dict):
        raise EvidenceError(f"lane_failures item #{index} must be an object")
    normalized: dict[str, Any] = {}
    for key in ["lane_id", "failure_kind", "observed_marker"]:
        value = item.get(key)
        if not isinstance(value, str) or not value.strip():
            raise EvidenceError(f"lane_failures[{index}].{key} must be a non-empty string")
        normalized[key] = value.strip()
    if normalized["failure_kind"] not in LANE_FAILURE_KINDS:
        raise EvidenceError(
            f"lane_failures[{index}].failure_kind is unsupported: {normalized['failure_kind']}"
        )
    detail = item.get("detail")
    if isinstance(detail, str) and detail.strip():
        normalized["detail"] = detail.strip()
    pr = item.get("pr")
    if pr is not None:
        if not isinstance(pr, int) or isinstance(pr, bool) or pr <= 0:
            raise EvidenceError(f"lane_failures[{index}].pr must be a positive integer")
        normalized["pr"] = pr
    head_sha = item.get("head_sha")
    if head_sha is not None:
        if not isinstance(head_sha, str) or not head_sha.strip():
            raise EvidenceError(f"lane_failures[{index}].head_sha must be a non-empty string")
        normalized["head_sha"] = head_sha.strip()
    return normalized


def load_lane_failures(path: str | None) -> list[dict[str, Any]]:
    if path is None:
        return []
    payload = _read_json_file(path, "lane failures")
    if isinstance(payload, dict):
        payload = payload.get("lane_failures")
    if not isinstance(payload, list):
        raise EvidenceError("lane failures file must contain a list or lane_failures list")
    return [_normalize_lane_failure(item, index) for index, item in enumerate(payload, start=1)]

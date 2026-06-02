#!/usr/bin/env python3
"""Verify live state before making claims in final answers or PR comments."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path


CHECKLISTS = {
    "latest": [
        "fetch the remote ref immediately before judging freshness",
        "record active branch, local ref, remote ref, ahead/behind count",
        "record dirty worktree state separately from ref freshness",
    ],
    "pr-ready": [
        "record PR state, draft state, mergeability, and target branch",
        "record CI/check conclusions from the current PR head",
        "record review decision and latest review/comment evidence",
    ],
    "merged": [
        "record remote PR state and merge commit",
        "fetch the target branch before local parity checks",
        "prove the target branch contains the merge commit",
    ],
    "running": [
        "record process identity from the OS, not memory",
        "record command line or executable path",
        "probe port or health endpoint when user-visible service state matters",
    ],
    "deployed": [
        "probe the live URL or health endpoint",
        "record version, image, commit, or release evidence from the live surface",
        "separate HTTP reachability from version/ref parity",
    ],
    "published": [
        "record registry metadata from the registry, not repo files alone",
        "compare package version to repo tag or release",
        "compare published artifact/readme checksum when artifact parity matters",
    ],
}


class LiveTruthError(Exception):
    """Raised for invalid inputs or command execution errors."""


def _value_text(value: object) -> str:
    if value is True:
        return "yes"
    if value is False:
        return "no"
    if value is None:
        return "unknown"
    if isinstance(value, (list, tuple)):
        return ", ".join(str(item) for item in value) if value else "none"
    return str(value)


def print_report(
    claim_type: str,
    verdict: str,
    facts: list[tuple[str, object]],
    inferences: list[str],
    gaps: list[str],
) -> int:
    print(f"LIVE-TRUTH {claim_type}")
    print(f"verdict: {verdict}")
    print("facts:")
    if facts:
        for key, value in facts:
            print(f"- {key}: {_value_text(value)}")
    else:
        print("- none")
    print("inferences:")
    if inferences:
        for item in inferences:
            print(f"- {item}")
    else:
        print("- none")
    print("unresolved_gaps:")
    if gaps:
        for item in gaps:
            print(f"- {item}")
    else:
        print("- none")
    return 0 if verdict == "pass" else 1


def run_process(args: list[str], cwd: Path | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(args, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and proc.returncode != 0:
        details = (proc.stderr or proc.stdout).strip()
        detail_suffix = f": {details}" if details else ""
        raise LiveTruthError(f"{args[0]} failed with exit {proc.returncode}{detail_suffix}")
    return proc


def git_text(repo: Path, args: list[str]) -> str:
    return run_process(["git", *args], cwd=repo).stdout.strip()


def short_sha(value: str) -> str:
    return value[:12] if value else "unknown"


def load_json_fixture(path: str) -> dict[str, object]:
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except OSError as exc:
        raise LiveTruthError(f"cannot read fixture {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise LiveTruthError(f"invalid JSON fixture {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise LiveTruthError(f"fixture must be a JSON object: {path}")
    return data


def normalize_version(value: object) -> str:
    text = str(value or "").strip()
    return text[1:] if text.startswith("v") else text


def checksum_file(path: str) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def command_checklist(args: argparse.Namespace) -> int:
    selected = [args.claim_type] if args.claim_type else list(CHECKLISTS)
    print("LIVE-TRUTH checklist")
    print("artifact_sections: facts, inferences, unresolved_gaps")
    for claim_type in selected:
        if claim_type not in CHECKLISTS:
            raise LiveTruthError(f"unknown claim type: {claim_type}")
        print(f"\n{claim_type}:")
        for item in CHECKLISTS[claim_type]:
            print(f"- {item}")
    return 0


def command_latest(args: argparse.Namespace) -> int:
    repo = Path(args.repo).resolve()
    facts: list[tuple[str, object]] = [("repo", repo)]
    inferences: list[str] = []
    gaps: list[str] = []
    failures: list[str] = []

    try:
        top_level = git_text(repo, ["rev-parse", "--show-toplevel"])
        active_branch = git_text(repo, ["rev-parse", "--abbrev-ref", "HEAD"])
    except LiveTruthError as exc:
        return print_report("latest", "gap", facts, [], [str(exc)])

    branch = args.branch or active_branch
    remote_ref = f"refs/remotes/{args.remote}/{branch}"
    facts.extend(
        [
            ("top_level", top_level),
            ("active_branch", active_branch),
            ("branch", branch),
            ("remote", args.remote),
        ]
    )

    if active_branch != branch:
        gaps.append(f"active branch is {active_branch}, not {branch}")

    if not args.no_fetch:
        fetch_proc = run_process(["git", "fetch", "--quiet", args.remote, branch], cwd=repo, check=False)
        facts.append(("fetch_exit", fetch_proc.returncode))
        if fetch_proc.returncode != 0:
            gaps.append((fetch_proc.stderr or fetch_proc.stdout or "git fetch failed").strip())
    else:
        facts.append(("fetch_exit", "skipped"))
        gaps.append("remote ref was not freshly fetched")

    try:
        local_sha = git_text(repo, ["rev-parse", branch])
        remote_sha = git_text(repo, ["rev-parse", remote_ref])
        dirty_state = git_text(repo, ["status", "--porcelain"])
        ahead_behind = git_text(repo, ["rev-list", "--left-right", "--count", f"{branch}...{remote_ref}"])
    except LiveTruthError as exc:
        return print_report("latest", "gap", facts, inferences, gaps + [str(exc)])

    ahead_text, behind_text = ahead_behind.split()
    ahead = int(ahead_text)
    behind = int(behind_text)
    dirty = bool(dirty_state)
    facts.extend(
        [
            ("local_ref", short_sha(local_sha)),
            ("remote_ref", short_sha(remote_sha)),
            ("ahead", ahead),
            ("behind", behind),
            ("dirty", dirty),
        ]
    )

    if behind:
        failures.append(f"local branch is behind {args.remote}/{branch} by {behind} commit(s)")
    else:
        inferences.append(f"local branch contains the fetched {args.remote}/{branch} ref")

    if ahead:
        gaps.append(f"local branch has {ahead} commit(s) not present on {args.remote}/{branch}")
    if dirty:
        gaps.append("worktree has uncommitted changes")
    if local_sha == remote_sha and not dirty:
        inferences.append("local ref, remote ref, and clean worktree support a latest claim")

    verdict = "fail" if failures else ("gap" if gaps else "pass")
    return print_report("latest", verdict, facts, inferences + failures, gaps)


def gh_pr_view(repo: str, pr_number: str, fields: list[str]) -> dict[str, object]:
    if not shutil.which("gh"):
        raise LiveTruthError("gh CLI is not available")
    proc = run_process(["gh", "pr", "view", pr_number, "--repo", repo, "--json", ",".join(fields)])
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise LiveTruthError(f"gh returned invalid JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise LiveTruthError("gh returned non-object JSON")
    return data


def pr_data_from_args(args: argparse.Namespace, fields: list[str]) -> dict[str, object]:
    if args.fixture:
        return load_json_fixture(args.fixture)
    if not args.repo or not args.pr:
        raise LiveTruthError("live PR checks require --repo and --pr, or use --fixture")
    return gh_pr_view(args.repo, args.pr, fields)


def check_state(item: object) -> tuple[str, str]:
    if not isinstance(item, dict):
        return ("unknown", "malformed check item")
    name = str(item.get("name") or item.get("context") or item.get("workflowName") or "unnamed")
    status = str(item.get("status") or item.get("state") or "").upper()
    conclusion = str(item.get("conclusion") or item.get("state") or "").upper()
    if conclusion in {"SUCCESS", "NEUTRAL", "SKIPPED"}:
        return ("pass", name)
    if status in {"COMPLETED"} and conclusion in {"SUCCESS", "NEUTRAL", "SKIPPED"}:
        return ("pass", name)
    if conclusion in {"FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED"}:
        return ("fail", name)
    if status in {"PENDING", "QUEUED", "IN_PROGRESS", "REQUESTED", "WAITING"}:
        return ("gap", name)
    return ("gap", name)


def command_pr_ready(args: argparse.Namespace) -> int:
    fields = [
        "state",
        "isDraft",
        "mergeable",
        "reviewDecision",
        "statusCheckRollup",
        "url",
        "headRefOid",
        "baseRefName",
        "updatedAt",
        "comments",
        "latestReviews",
    ]
    data = pr_data_from_args(args, fields)
    checks = data.get("statusCheckRollup") or []
    if not isinstance(checks, list):
        raise LiveTruthError("statusCheckRollup must be a list")

    check_results = [check_state(item) for item in checks]
    passing_checks = [name for state, name in check_results if state == "pass"]
    failing_checks = [name for state, name in check_results if state == "fail"]
    pending_checks = [name for state, name in check_results if state == "gap"]
    state = str(data.get("state") or "unknown").upper()
    draft = bool(data.get("isDraft"))
    mergeable = str(data.get("mergeable") or "unknown").upper()
    review_decision = str(data.get("reviewDecision") or "unknown").upper()
    comments = data.get("comments") if isinstance(data.get("comments"), list) else []
    reviews = data.get("latestReviews") if isinstance(data.get("latestReviews"), list) else []

    facts = [
        ("url", data.get("url")),
        ("state", state),
        ("draft", draft),
        ("mergeable", mergeable),
        ("base_ref", data.get("baseRefName")),
        ("head_ref", short_sha(str(data.get("headRefOid") or ""))),
        ("updated_at", data.get("updatedAt")),
        ("review_decision", review_decision),
        ("latest_reviews", len(reviews)),
        ("comments", len(comments)),
        ("checks_total", len(checks)),
        ("checks_passing", len(passing_checks)),
        ("checks_blocking", len(failing_checks)),
        ("checks_pending", len(pending_checks)),
    ]
    inferences: list[str] = []
    gaps: list[str] = []
    failures: list[str] = []

    if state != "OPEN":
        failures.append(f"PR state is {state}, not OPEN")
    if draft:
        failures.append("PR is still a draft")
    if mergeable == "MERGEABLE":
        inferences.append("GitHub currently reports the PR as mergeable")
    elif mergeable == "UNKNOWN":
        gaps.append("GitHub mergeability is unknown")
    else:
        failures.append(f"GitHub mergeability is {mergeable}")
    if failing_checks:
        failures.append(f"blocking checks: {', '.join(failing_checks)}")
    if pending_checks:
        gaps.append(f"pending or unknown checks: {', '.join(pending_checks)}")
    if not checks:
        gaps.append("no CI/check evidence was present")
    if review_decision == "APPROVED":
        inferences.append("review decision is APPROVED")
    elif review_decision == "CHANGES_REQUESTED":
        failures.append("latest review decision requests changes")
    elif review_decision == "REVIEW_REQUIRED":
        failures.append("review decision is REVIEW_REQUIRED")
    elif review_decision in {"UNKNOWN", ""}:
        gaps.append("review decision is unknown")
    else:
        failures.append(f"review decision is {review_decision}, not APPROVED")

    if not failures and not gaps:
        inferences.append("PR-ready claim has state, mergeability, CI, and review evidence")
    verdict = "fail" if failures else ("gap" if gaps else "pass")
    return print_report("pr-ready", verdict, facts, inferences + failures, gaps)


def command_merged(args: argparse.Namespace) -> int:
    fields = ["state", "mergedAt", "mergeCommit", "url", "baseRefName", "headRefOid"]
    data = pr_data_from_args(args, fields)
    merge_commit = data.get("mergeCommit")
    if isinstance(merge_commit, dict):
        merge_sha = str(merge_commit.get("oid") or "")
    else:
        merge_sha = str(merge_commit or "")
    state = str(data.get("state") or "unknown").upper()
    facts = [
        ("url", data.get("url")),
        ("state", state),
        ("merged_at", data.get("mergedAt")),
        ("base_ref", data.get("baseRefName")),
        ("head_ref", short_sha(str(data.get("headRefOid") or ""))),
        ("merge_commit", short_sha(merge_sha)),
    ]
    inferences: list[str] = []
    gaps: list[str] = []
    failures: list[str] = []

    if state != "MERGED":
        failures.append(f"remote PR state is {state}, not MERGED")
    elif merge_sha:
        inferences.append("remote PR state and merge commit support a merged claim")
    else:
        gaps.append("merged PR has no merge commit evidence")

    if args.repo_path and args.remote and args.branch and merge_sha:
        repo_path = Path(args.repo_path).resolve()
        fetch_proc = run_process(["git", "fetch", "--quiet", args.remote, args.branch], cwd=repo_path, check=False)
        facts.append(("fetch_exit", fetch_proc.returncode))
        if fetch_proc.returncode != 0:
            gaps.append((fetch_proc.stderr or fetch_proc.stdout or "git fetch failed").strip())
        else:
            target_ref = f"refs/remotes/{args.remote}/{args.branch}"
            contains_proc = run_process(
                ["git", "merge-base", "--is-ancestor", merge_sha, target_ref],
                cwd=repo_path,
                check=False,
            )
            facts.append(("target_ref", target_ref))
            facts.append(("merge_commit_in_target", contains_proc.returncode == 0))
            if contains_proc.returncode == 0:
                inferences.append(f"{target_ref} contains the merge commit")
            else:
                failures.append(f"{target_ref} does not contain the merge commit")
    else:
        gaps.append("local target branch containment was not checked")

    verdict = "fail" if failures else ("gap" if gaps else "pass")
    return print_report("merged", verdict, facts, inferences + failures, gaps)


def command_running(args: argparse.Namespace) -> int:
    facts: list[tuple[str, object]] = []
    inferences: list[str] = []
    gaps: list[str] = []
    failures: list[str] = []

    if args.pid:
        proc = run_process(["ps", "-p", str(args.pid), "-o", "command="], check=False)
        command_line = proc.stdout.strip()
        facts.extend([("pid", args.pid), ("process_found", proc.returncode == 0), ("command_line", command_line)])
        if proc.returncode == 0:
            inferences.append("process exists in the OS process table")
            if args.command_contains:
                contains = args.command_contains in command_line
                facts.append(("command_contains", contains))
                if contains:
                    inferences.append("process command line matches expected text")
                else:
                    failures.append("process command line does not match expected text")
        else:
            failures.append("process is not running")
    else:
        gaps.append("no --pid evidence was provided")

    if args.health_url:
        status, detail = probe_url(args.health_url, args.timeout)
        facts.extend([("health_url", args.health_url), ("health_status", status), ("health_detail", detail)])
        if isinstance(status, int) and 200 <= status < 400:
            inferences.append("health endpoint is reachable")
        else:
            failures.append("health endpoint is not reachable")
    else:
        gaps.append("no health endpoint was probed")

    verdict = "fail" if failures else ("gap" if gaps else "pass")
    return print_report("running", verdict, facts, inferences + failures, gaps)


def probe_url(url: str, timeout: float) -> tuple[object, str]:
    request = urllib.request.Request(url, headers={"User-Agent": "vibeguard-live-truth/1"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read(4096).decode("utf-8", errors="replace")
            return response.status, body.replace("\n", " ")[:160]
    except urllib.error.HTTPError as exc:
        return exc.code, str(exc)
    except urllib.error.URLError as exc:
        return "error", str(exc.reason)
    except TimeoutError:
        return "error", "request timed out"


def command_deployed(args: argparse.Namespace) -> int:
    facts: list[tuple[str, object]] = [("url", args.url)]
    inferences: list[str] = []
    gaps: list[str] = []
    failures: list[str] = []

    status, detail = probe_url(args.url, args.timeout)
    facts.extend([("http_status", status), ("response_sample", detail)])
    if isinstance(status, int) and 200 <= status < 400:
        inferences.append("live URL is reachable")
    else:
        failures.append("live URL is not reachable")
    if args.expect_text:
        contains = args.expect_text in detail
        facts.append(("expected_text_found", contains))
        if contains:
            inferences.append("live response contains expected version/ref text")
        else:
            failures.append("live response does not contain expected version/ref text")
    else:
        gaps.append("no version/ref text expectation was checked")

    verdict = "fail" if failures else ("gap" if gaps else "pass")
    return print_report("deployed", verdict, facts, inferences + failures, gaps)


def command_published(args: argparse.Namespace) -> int:
    data: dict[str, object] = {}
    if args.fixture:
        data.update(load_json_fixture(args.fixture))
    if args.repo_readme:
        data["repo_readme_sha"] = checksum_file(args.repo_readme)
    if args.registry_readme:
        data["registry_readme_sha"] = checksum_file(args.registry_readme)

    facts = [
        ("package", data.get("package")),
        ("registry", data.get("registry")),
        ("registry_version", data.get("registry_version")),
        ("repo_tag", data.get("repo_tag")),
        ("repo_commit", short_sha(str(data.get("repo_commit") or ""))),
        ("registry_commit", short_sha(str(data.get("registry_commit") or ""))),
        ("repo_readme_sha", short_sha(str(data.get("repo_readme_sha") or ""))),
        ("registry_readme_sha", short_sha(str(data.get("registry_readme_sha") or ""))),
    ]
    inferences: list[str] = []
    gaps: list[str] = []
    failures: list[str] = []

    registry_version = data.get("registry_version")
    repo_tag = data.get("repo_tag")
    if registry_version and repo_tag:
        if normalize_version(registry_version) == normalize_version(repo_tag):
            inferences.append("registry version matches repo tag")
        else:
            failures.append("registry version differs from repo tag")
    else:
        gaps.append("registry version or repo tag evidence is missing")

    repo_commit = data.get("repo_commit")
    registry_commit = data.get("registry_commit")
    if repo_commit and registry_commit:
        if repo_commit == registry_commit:
            inferences.append("registry commit matches repo commit")
        else:
            failures.append("registry commit differs from repo commit")
    else:
        gaps.append("registry commit parity was not checked")

    repo_readme = data.get("repo_readme_sha")
    registry_readme = data.get("registry_readme_sha")
    if repo_readme and registry_readme:
        if repo_readme == registry_readme:
            inferences.append("registry README matches repo README checksum")
        else:
            failures.append("registry README differs from repo README checksum")
    else:
        gaps.append("artifact or README checksum parity was not checked")

    verdict = "fail" if failures else ("gap" if gaps else "pass")
    return print_report("published", verdict, facts, inferences + failures, gaps)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Produce compact facts/inferences/gaps artifacts for live-truth claims.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    checklist = subparsers.add_parser("checklist", help="Print evidence checklists for claim types")
    checklist.add_argument("claim_type", nargs="?", choices=sorted(CHECKLISTS))
    checklist.set_defaults(func=command_checklist)

    latest = subparsers.add_parser("latest", help="Verify git branch freshness against a remote ref")
    latest.add_argument("--repo", default=".", help="Git repository path")
    latest.add_argument("--remote", default="origin", help="Remote name")
    latest.add_argument("--branch", help="Branch name; defaults to the active branch")
    latest.add_argument("--no-fetch", action="store_true", help="Skip git fetch and report the gap")
    latest.set_defaults(func=command_latest)

    pr_ready = subparsers.add_parser("pr-ready", help="Verify PR readiness from GitHub or a JSON fixture")
    pr_ready.add_argument("--fixture", help="GitHub-like JSON fixture")
    pr_ready.add_argument("--repo", help="GitHub repository, for example owner/name")
    pr_ready.add_argument("--pr", help="Pull request number")
    pr_ready.set_defaults(func=command_pr_ready)

    merged = subparsers.add_parser("merged", help="Verify remote PR merge state and optional local parity")
    merged.add_argument("--fixture", help="GitHub-like JSON fixture")
    merged.add_argument("--repo", help="GitHub repository, for example owner/name")
    merged.add_argument("--pr", help="Pull request number")
    merged.add_argument("--repo-path", help="Local git repository for target branch containment checks")
    merged.add_argument("--remote", help="Remote name for target branch containment checks")
    merged.add_argument("--branch", help="Target branch for containment checks")
    merged.set_defaults(func=command_merged)

    running = subparsers.add_parser("running", help="Verify process and optional health endpoint state")
    running.add_argument("--pid", type=int, help="Process ID to verify")
    running.add_argument("--command-contains", help="Expected text in process command line")
    running.add_argument("--health-url", help="Health endpoint to probe")
    running.add_argument("--timeout", type=float, default=5.0, help="HTTP timeout in seconds")
    running.set_defaults(func=command_running)

    deployed = subparsers.add_parser("deployed", help="Verify live URL reachability and optional version text")
    deployed.add_argument("--url", required=True, help="Live URL or health endpoint")
    deployed.add_argument("--expect-text", help="Expected version/ref text in the response sample")
    deployed.add_argument("--timeout", type=float, default=5.0, help="HTTP timeout in seconds")
    deployed.set_defaults(func=command_deployed)

    published = subparsers.add_parser("published", help="Verify registry/package metadata parity")
    published.add_argument("--fixture", help="Published artifact JSON fixture")
    published.add_argument("--repo-readme", help="Repo README/artifact file to hash")
    published.add_argument("--registry-readme", help="Published README/artifact file to hash")
    published.set_defaults(func=command_published)

    return parser


def main(argv: list[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except LiveTruthError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

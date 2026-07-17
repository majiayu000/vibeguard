#!/usr/bin/env bash
# VibeGuard CI: Verify backtick path references in Git-tracked Markdown.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
DOCS_DIR="${1:-$REPO_DIR}"
REPO_ROOT="${2:-$REPO_DIR}"

python3 - "$DOCS_DIR" "$REPO_ROOT" <<'PY'
import fnmatch
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath

docs_dir = Path(sys.argv[1]).resolve()
repo_root = Path(sys.argv[2]).resolve()
allowlist_file = repo_root / ".vibeguard-doc-paths-allowlist"

extensions = (
    r"\.py|\.ts|\.tsx|\.js|\.jsx|\.sh|\.rs|\.go|\.toml|\.json|\.yaml|\.yml"
    r"|\.md|\.css|\.html|\.sql|\.lock|\.cfg|\.ini|\.env"
)
path_re = re.compile(r"`([A-Za-z0-9_./-]+(?:" + extensions + r"))`")
skip_prefixes = ("http://", "https://", "~/", "your/", "project/")
skip_contains = ("*", "<", ">", "${")
categories = {"runtime_alias", "installed_alias", "historical", "planned"}


@dataclass
class AllowEntry:
    reference: str
    category: str
    scope_glob: str
    canonical_source: str
    reason: str
    line_number: int
    hits: list[tuple[str, int, int, str]] = field(default_factory=list)


def run_git_ls_files() -> list[str]:
    try:
        result = subprocess.run(
            ["git", "-C", os.fspath(repo_root), "ls-files", "-z"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except OSError as exc:
        raise RuntimeError(f"cannot execute git: {exc}") from exc
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"git ls-files failed: {detail or f'exit {result.returncode}'}")
    return sorted(os.fsdecode(item) for item in result.stdout.split(b"\0") if item)


def scope_is_allowed(category: str, scope_glob: str) -> bool:
    if category == "historical":
        return (
            scope_glob == "CHANGELOG.md"
            or scope_glob.startswith("docs/internal/")
            or scope_glob.startswith("plan/")
        )
    if category == "planned":
        return scope_glob.startswith("docs/internal/") or scope_glob.startswith("plan/")
    if category == "installed_alias":
        return not any(char in scope_glob for char in "*?[") and scope_glob.endswith(".md")
    return True


def safe_repo_relative(value: str) -> bool:
    path = PurePosixPath(value.rstrip("/"))
    return bool(value) and not path.is_absolute() and ".." not in path.parts


def load_manifest_pairs() -> set[tuple[str, str]]:
    helper = repo_root / "scripts/lib/vibeguard_manifest.py"
    try:
        result = subprocess.run(
            [sys.executable, os.fspath(helper), "rule-links"],
            cwd=repo_root,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except OSError as exc:
        raise RuntimeError(f"cannot execute rule-links manifest helper: {exc}") from exc
    if result.returncode != 0:
        detail = result.stderr.strip()
        raise RuntimeError(f"rule-links failed: {detail or f'exit {result.returncode}'}")
    pairs: set[tuple[str, str]] = set()
    for line_number, line in enumerate(result.stdout.splitlines(), 1):
        fields = line.split("\t")
        if len(fields) != 3 or not all(fields):
            raise RuntimeError(f"rule-links line {line_number} is not a non-empty 3-field row")
        pairs.add((fields[0], fields[1]))
    return pairs


def load_allowlist(
    tracked_paths: set[str], failures: list[str]
) -> list[AllowEntry]:
    if not allowlist_file.exists():
        return []
    try:
        lines = allowlist_file.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as exc:
        failures.append(f"FAIL: .vibeguard-doc-paths-allowlist: allowlist_read_error: {exc}")
        return []

    entries: list[AllowEntry] = []
    seen: set[tuple[str, str, str, str, str]] = set()
    needs_manifest = False
    for line_number, line in enumerate(lines, 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        fields = tuple(part.strip() for part in line.split("|"))
        if len(fields) != 5 or not all(fields):
            failures.append(
                f"FAIL: .vibeguard-doc-paths-allowlist:{line_number}: invalid_allowlist_format: expected 5 non-empty pipe-delimited fields"
            )
            continue
        if fields in seen:
            failures.append(
                f"FAIL: .vibeguard-doc-paths-allowlist:{line_number}: duplicate_allowlist_entry: {fields[0]}"
            )
            continue
        seen.add(fields)
        entry = AllowEntry(*fields, line_number=line_number)
        entries.append(entry)

        if entry.category not in categories:
            failures.append(
                f"FAIL: .vibeguard-doc-paths-allowlist:{line_number}: invalid_allowlist_category: {entry.category}"
            )
            continue
        if not safe_repo_relative(entry.reference) or not safe_repo_relative(entry.scope_glob):
            failures.append(
                f"FAIL: .vibeguard-doc-paths-allowlist:{line_number}: invalid_allowlist_path: reference and scope must be repo-relative"
            )
        if not scope_is_allowed(entry.category, entry.scope_glob):
            failures.append(
                f"FAIL: .vibeguard-doc-paths-allowlist:{line_number}: invalid_allowlist_scope: {entry.scope_glob} is not allowed for {entry.category}"
            )

        source = entry.canonical_source
        if entry.category == "runtime_alias":
            source_key = source.rstrip("/")
            tracked_source = source_key in tracked_paths or any(
                path.startswith(f"{source_key}/") for path in tracked_paths
            )
            if (
                not safe_repo_relative(source)
                or entry.reference != f"vibeguard/{source}"
                or not tracked_source
            ):
                failures.append(
                    f"FAIL: .vibeguard-doc-paths-allowlist:{line_number}: invalid_runtime_alias: {entry.reference} -> {source}"
                )
        elif entry.category == "installed_alias":
            needs_manifest = True
            if not safe_repo_relative(source) or source == "-":
                failures.append(
                    f"FAIL: .vibeguard-doc-paths-allowlist:{line_number}: invalid_installed_source: {source}"
                )
        elif source != "-":
            failures.append(
                f"FAIL: .vibeguard-doc-paths-allowlist:{line_number}: invalid_absent_source: {entry.category} canonical_source must be -"
            )
        elif (repo_root / entry.reference).exists():
            failures.append(
                f"FAIL: .vibeguard-doc-paths-allowlist:{line_number}: unnecessary_allowlist_entry: {entry.reference} exists"
            )

    if needs_manifest:
        try:
            pairs = load_manifest_pairs()
        except RuntimeError as exc:
            failures.append(
                f"FAIL: .vibeguard-doc-paths-allowlist: manifest_mapping_error: {exc}"
            )
            pairs = set()
        for entry in entries:
            if entry.category == "installed_alias" and (
                entry.canonical_source,
                entry.reference,
            ) not in pairs:
                failures.append(
                    f"FAIL: .vibeguard-doc-paths-allowlist:{entry.line_number}: invalid_installed_alias: {entry.canonical_source} -> {entry.reference}"
                )
    return entries


def should_skip(path_str: str) -> bool:
    if any(path_str.startswith(prefix) for prefix in skip_prefixes):
        return True
    if any(marker in path_str for marker in skip_contains):
        return True
    if "/" not in path_str or path_str.startswith("."):
        return True
    return False


def main() -> int:
    failures: list[str] = []
    try:
        docs_prefix = docs_dir.relative_to(repo_root).as_posix()
    except ValueError:
        print(f"FAIL: {docs_dir}: invalid_docs_root: docs directory must be inside repo root")
        return 1

    try:
        tracked = run_git_ls_files()
    except RuntimeError as exc:
        print(f"FAIL: {repo_root}: git_enumeration_error: {exc}")
        return 1
    tracked_set = set(tracked)
    md_paths = [
        path
        for path in tracked
        if path.endswith(".md")
        and (docs_prefix == "." or path == docs_prefix or path.startswith(f"{docs_prefix}/"))
    ]
    entries = load_allowlist(tracked_set, failures)

    ok_count = 0
    for relative_path in md_paths:
        md_file = repo_root / relative_path
        try:
            content = md_file.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            failures.append(
                f"FAIL: {relative_path}: markdown_read_error: {exc}"
            )
            continue

        file_failures = 0
        reference_count = 0
        for line_number, line in enumerate(content.splitlines(), 1):
            for match in path_re.finditer(line):
                reference = match.group(1)
                if should_skip(reference):
                    continue
                column = match.start(1) + 1
                occurrence = (relative_path, line_number, column, reference)
                matching_entries = [
                    entry
                    for entry in entries
                    if entry.reference == reference
                    and fnmatch.fnmatchcase(relative_path, entry.scope_glob)
                ]
                if len(matching_entries) > 1:
                    failures.append(
                        f"FAIL: {relative_path}:{line_number}:{column}: overlapping_allowlist_entries: {reference}"
                    )
                    file_failures += 1
                    continue
                if matching_entries:
                    matching_entries[0].hits.append(occurrence)
                    continue

                reference_count += 1
                repo_path = repo_root / reference
                relative_reference = md_file.parent / reference
                if not repo_path.exists() and not relative_reference.exists():
                    failures.append(
                        f"FAIL: {relative_path}:{line_number}:{column}: missing_path_reference: `{reference}`"
                    )
                    file_failures += 1
        if file_failures == 0 and reference_count > 0:
            print(f"OK: {relative_path} — {reference_count} references, all valid")
            ok_count += 1

    for entry in entries:
        if not entry.hits:
            failures.append(
                f"FAIL: .vibeguard-doc-paths-allowlist:{entry.line_number}: unused_allowlist_entry: {entry.reference} in {entry.scope_glob}"
            )

    for failure in failures:
        print(failure)
    if failures:
        print(f"\n{len(failures)} doc path or allowlist error(s) found")
        return 1
    if ok_count == 0:
        print("No ordinary path references found in tracked Markdown")
    else:
        print(f"\nAll {ok_count} files with ordinary path references validated successfully")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY

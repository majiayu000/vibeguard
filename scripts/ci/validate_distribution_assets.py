#!/usr/bin/env python3
"""Fail when a tracked distribution asset has no verifiable lifecycle owner."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path, PurePosixPath


VALIDATOR_PATH = "scripts/ci/validate_distribution_assets.py"
FORMAL_EVIDENCE_PATHS = {
    "schemas/install-modules.json",
    "skills-lock.json",
}
EXCLUDED_CONSUMER_PREFIXES = (
    "docs/specs/",
    "plan/",
    "tests/",
)
ROOT_CONFIG_SUFFIXES = {".json", ".toml", ".yaml", ".yml"}
TOKEN_BYTES = frozenset(
    b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./*-"
)


class ValidationError(RuntimeError):
    """Raised when repository evidence cannot be collected safely."""


def collect_git_lines(repo: Path, *args: str) -> list[str]:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "unknown git error"
        raise ValidationError(f"git {' '.join(args)} failed: {detail}")
    return [line for line in result.stdout.splitlines() if line]


def collect_assets(tracked_paths: list[str]) -> list[str]:
    assets: set[str] = set()
    for raw_path in tracked_paths:
        path = PurePosixPath(raw_path)
        parts = path.parts
        if len(parts) == 3 and parts[0] == "skills" and parts[2] == "SKILL.md":
            assets.add(raw_path)
        elif len(parts) >= 2 and parts[0] == "templates":
            assets.add(raw_path)
        elif len(parts) == 1 and path.suffix in ROOT_CONFIG_SUFFIXES:
            assets.add(raw_path)
    return sorted(assets)


def iter_json_strings(value: object):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key, item in value.items():
            if isinstance(key, str):
                yield key
            yield from iter_json_strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from iter_json_strings(item)


def load_json_strings(path: Path) -> set[str]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise ValidationError(f"cannot read {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ValidationError(f"invalid JSON in {path}: {exc.msg}") from exc
    return set(iter_json_strings(data))


def manifest_installs(asset: str, manifest_strings: set[str]) -> bool:
    if asset in manifest_strings:
        return True
    if not asset.startswith("skills/"):
        return False
    return any(
        asset == f"{entry.rstrip('/')}/SKILL.md"
        for entry in manifest_strings
        if entry.startswith("skills/")
    )


def contains_exact_path(content: bytes, asset: str) -> bool:
    needle = asset.encode("utf-8")
    start = 0
    while True:
        index = content.find(needle, start)
        if index < 0:
            return False
        before = content[index - 1] if index > 0 else None
        after_index = index + len(needle)
        after = content[after_index] if after_index < len(content) else None
        repo_prefix = before == ord("/") and index >= 2 and content[index - 2] == ord("}")
        if (before is None or before not in TOKEN_BYTES or repo_prefix) and (
            after is None or after not in TOKEN_BYTES
        ):
            return True
        start = index + 1


def read_tracked_file(repo: Path, relative_path: str) -> bytes:
    try:
        return (repo / relative_path).read_bytes()
    except OSError as exc:
        raise ValidationError(f"cannot read tracked file {relative_path}: {exc}") from exc


def find_consumer(
    repo: Path,
    asset: str,
    tracked_paths: list[str],
) -> str | None:
    for relative_path in tracked_paths:
        if relative_path in {
            asset,
            "CONTRIBUTING.md",
            VALIDATOR_PATH,
            *FORMAL_EVIDENCE_PATHS,
        }:
            continue
        if relative_path.startswith(EXCLUDED_CONSUMER_PREFIXES):
            continue
        if contains_exact_path(read_tracked_file(repo, relative_path), asset):
            return relative_path
    return None


def manual_declaration(contributing: bytes, asset: str) -> bool:
    return f"`{asset}`".encode("utf-8") in contributing


def validate_distribution_assets(repo: Path) -> int:
    tracked_paths = collect_git_lines(repo, "ls-files")
    assets = collect_assets(tracked_paths)
    manifest_strings = load_json_strings(repo / "schemas/install-modules.json")
    skill_lock_strings = load_json_strings(repo / "skills-lock.json")
    contributing = read_tracked_file(repo, "CONTRIBUTING.md")

    failures: list[str] = []
    for asset in assets:
        evidence: str | None = None
        if manifest_installs(asset, manifest_strings):
            evidence = "install_module"
        elif asset in skill_lock_strings:
            evidence = "skills_lock"
        else:
            consumer = find_consumer(repo, asset, tracked_paths)
            if consumer is not None:
                evidence = f"consumer:{consumer}"
            elif manual_declaration(contributing, asset):
                evidence = "manual:CONTRIBUTING.md"

        if evidence is None:
            failures.append(asset)
            print(f"FAIL: unowned distribution asset: {asset}", file=sys.stderr)
        else:
            print(f"OK: {asset} <- {evidence}")

    if failures:
        print(
            f"Distribution asset validation failed: {len(failures)} unowned asset(s)",
            file=sys.stderr,
        )
        return 1
    print(f"All {len(assets)} tracked distribution assets have lifecycle evidence")
    return 0


def main() -> int:
    repo = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    if len(sys.argv) > 2:
        print("usage: validate_distribution_assets.py [repo]", file=sys.stderr)
        return 2
    try:
        return validate_distribution_assets(repo)
    except ValidationError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

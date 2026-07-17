#!/usr/bin/env bash
# VibeGuard CI: Detect leaked personal paths in Git-tracked files.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

python3 - "${REPO_DIR}" <<'PY'
import os
import re
import subprocess
import sys
from pathlib import Path

repo_dir = Path(sys.argv[1]).resolve()
personal_path_re = re.compile(rb"/(?:Users|home)/[A-Za-z0-9._-]+/")
tilde_assignment_re = re.compile(rb"=[ \t]*~/[A-Za-z]")


def tracked_paths() -> list[bytes]:
    try:
        result = subprocess.run(
            ["git", "-C", os.fspath(repo_dir), "ls-files", "-z"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except OSError as exc:
        raise RuntimeError(f"cannot execute git: {exc}") from exc
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"git ls-files failed: {detail or f'exit {result.returncode}'}")
    return sorted(path for path in result.stdout.split(b"\0") if path)


def display_path(path_bytes: bytes) -> str:
    return os.fsdecode(path_bytes)


def read_tracked(path_bytes: bytes) -> bytes:
    path = repo_dir / display_path(path_bytes)
    try:
        if path.is_symlink():
            return os.fsencode(os.readlink(path))
        return path.read_bytes()
    except OSError as exc:
        raise RuntimeError(f"cannot read tracked file {display_path(path_bytes)}: {exc}") from exc


def main() -> int:
    print("Scanning Git-tracked files for hardcoded personal paths...")
    try:
        paths = tracked_paths()
    except RuntimeError as exc:
        print(f"FAIL: {repo_dir}: scan_error: {exc}")
        return 1

    failures: list[str] = []
    warnings: list[str] = []
    for path_bytes in paths:
        try:
            content = read_tracked(path_bytes)
        except RuntimeError as exc:
            failures.append(f"FAIL: {display_path(path_bytes)}: scan_error: {exc}")
            continue
        if b"\0" in content:
            continue

        path_text = display_path(path_bytes)
        for line_number, line in enumerate(content.splitlines(), 1):
            if personal_path_re.search(line):
                rendered = line.decode("utf-8", errors="replace").strip()
                failures.append(
                    f"FAIL: {path_text}:{line_number}: hardcoded_personal_path: {rendered}"
                )

            if not path_text.endswith(".sh") or not tilde_assignment_re.search(line):
                continue
            stripped = line.lstrip()
            if stripped.startswith(b"#") or b"echo " in stripped or b"printf " in stripped:
                continue
            rendered = line.decode("utf-8", errors="replace").strip()
            warnings.append(
                f"WARN: {path_text}:{line_number}: prefer_home_variable: {rendered}"
            )

    for warning in warnings:
        print(warning)
    for failure in failures:
        print(failure)

    if failures:
        print(f"FAILED: {len(failures)} personal-path or scan error(s) detected.")
        print("Fix: use $HOME, a repository-relative path, or an explicit placeholder.")
        return 1
    print("No hardcoded personal paths found in Git-tracked files.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY

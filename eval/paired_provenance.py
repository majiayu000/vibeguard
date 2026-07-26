"""Bind paired-eval inputs to an immutable Git commit."""

from __future__ import annotations

import subprocess
from pathlib import Path


class PairedProvenanceError(ValueError):
    """Raised when evaluated inputs cannot be attributed to one commit."""


def _run_git(repo_root: Path, args: list[str]) -> str:
    try:
        result = subprocess.run(
            ["git", *args],
            cwd=repo_root,
            check=True,
            capture_output=True,
            text=True,
        )
    except OSError as exc:
        raise PairedProvenanceError(
            f"cannot validate evaluated inputs: {exc}"
        ) from exc
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or str(exc)).strip()
        raise PairedProvenanceError(
            f"cannot validate evaluated inputs: {detail}"
        ) from exc
    return result.stdout


def pin_evaluated_inputs(
    input_paths: list[Path],
    *,
    expected_commit: str | None = None,
    repo_root: Path,
) -> str:
    """Return HEAD only when every evaluated input is tracked and clean there."""
    root = repo_root.resolve()
    relative_paths: list[str] = []
    directories: set[str] = set()
    for path in input_paths:
        resolved = path.resolve()
        try:
            relative = resolved.relative_to(root).as_posix()
        except ValueError as exc:
            raise PairedProvenanceError(
                f"evaluated input is outside the repository: {resolved}"
            ) from exc
        relative_paths.append(relative)
        if resolved.is_dir():
            directories.add(relative.rstrip("/") + "/")
    relative_paths = list(dict.fromkeys(relative_paths))

    commit = _run_git(root, ["rev-parse", "HEAD"]).strip()
    if not commit:
        raise PairedProvenanceError("cannot resolve evaluated commit")
    if expected_commit is not None and commit != expected_commit:
        raise PairedProvenanceError(
            "evaluated commit changed while inputs were being prepared"
        )

    dirty = _run_git(
        root,
        [
            "status",
            "--porcelain=v1",
            "--untracked-files=all",
            "--",
            *relative_paths,
        ],
    ).strip()
    if dirty:
        raise PairedProvenanceError(
            "evaluated inputs contain uncommitted changes: "
            + "; ".join(dirty.splitlines())
        )

    tracked_paths = set(
        _run_git(root, ["ls-tree", "-r", "--name-only", commit]).splitlines()
    )
    for relative in relative_paths:
        directory_prefix = relative.rstrip("/") + "/"
        if directory_prefix in directories:
            tracked = any(path.startswith(directory_prefix) for path in tracked_paths)
        else:
            tracked = relative in tracked_paths
        if not tracked:
            raise PairedProvenanceError(
                f"evaluated input is not present in commit {commit}: {relative}"
            )
    return commit

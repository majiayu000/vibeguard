"""Bind paired-eval inputs to an immutable Git commit."""

from __future__ import annotations

import ast
import subprocess
from pathlib import Path


class PairedProvenanceError(ValueError):
    """Raised when evaluated inputs cannot be attributed to one commit."""


def _module_candidates(module: str, roots: list[Path]) -> list[Path]:
    relative = Path(*module.split("."))
    return [
        candidate
        for root in roots
        for candidate in (
            root / relative.with_suffix(".py"),
            root / relative / "__init__.py",
        )
        if candidate.is_file()
    ]


def local_python_dependency_paths(
    entry_paths: list[Path],
    *,
    module_roots: list[Path],
) -> list[Path]:
    """Return the recursive repository-local Python import closure."""
    roots = [root.resolve() for root in module_roots]
    pending = [path.resolve() for path in entry_paths]
    dependencies: set[Path] = set()
    while pending:
        source_path = pending.pop()
        if source_path in dependencies:
            continue
        dependencies.add(source_path)
        try:
            tree = ast.parse(
                source_path.read_text(encoding="utf-8"),
                filename=str(source_path),
            )
        except (OSError, SyntaxError, UnicodeError) as exc:
            raise PairedProvenanceError(
                f"cannot inspect evaluator dependency {source_path}: {exc}"
            ) from exc

        discovered: list[Path] = []
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    discovered.extend(_module_candidates(alias.name, roots))
            elif isinstance(node, ast.ImportFrom):
                if node.level:
                    relative_root = source_path.parent
                    for _ in range(node.level - 1):
                        relative_root = relative_root.parent
                    if node.module:
                        discovered.extend(
                            _module_candidates(node.module, [relative_root])
                        )
                    else:
                        for alias in node.names:
                            discovered.extend(
                                _module_candidates(alias.name, [relative_root])
                            )
                elif node.module:
                    discovered.extend(_module_candidates(node.module, roots))
        pending.extend(discovered)
    return sorted(dependencies)


def evaluated_provenance_paths(
    *,
    rules_dir: Path,
    core_file: Path,
    target_path: Path,
    non_target_path: Path,
    thresholds_path: Path,
) -> list[Path]:
    """Return every repository input that can affect a paired-eval verdict."""
    repo_root = Path(__file__).resolve().parents[1]
    implementation_paths = local_python_dependency_paths(
        [
            repo_root / "eval" / "run_paired_eval.py",
            repo_root / "scripts" / "lib" / "vibeguard_manifest.py",
        ],
        module_roots=[
            repo_root / "eval",
            repo_root / "scripts" / "lib",
        ],
    )
    return [
        rules_dir,
        *sorted(rules_dir.rglob("*.md")),
        core_file,
        target_path,
        non_target_path,
        thresholds_path,
        repo_root / "eval" / "model_baseline.json",
        *implementation_paths,
    ]


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

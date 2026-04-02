#!/usr/bin/env python3
"""Dead Shell Detector — Detects Python-compatible shell files that only contain re-exports.

Scan the project directory for files containing only import statements, docstrings, and __all__ assignments,
These files are usually backward-compatible shells and should be deleted directly.

How to use:
    python3 check_dead_shims.py [target_dir]
    python3 check_dead_shims.py [target_dir] --strict # Exit code 1 if there is a dead shell
"""

import ast
import os
import sys
from pathlib import Path

DEFAULT_TARGET_DIR = Path(__file__).resolve().parent.parent / "app"

SKIP_DIRS: set[str] = {"__pycache__", ".git", "tests", "node_modules", ".venv"}
SKIP_FILES: set[str] = {"__init__.py"}

ALLOWLIST_FILENAME = ".vibeguard-dead-shims-allowlist"


def load_allowlist(target_dir: Path) -> set[str]:
    allowlist_file = target_dir / ALLOWLIST_FILENAME
    if not allowlist_file.exists():
        return set()
    entries: set[str] = set()
    for line in allowlist_file.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            entries.add(stripped)
    return entries


def _is_docstring_expr(node: ast.stmt) -> bool:
    return (
        isinstance(node, ast.Expr)
        and isinstance(node.value, ast.Constant)
        and isinstance(node.value.value, str)
    )


def _is_all_assignment(node: ast.stmt) -> bool:
    if isinstance(node, ast.Assign):
        return bool(node.targets) and all(
            isinstance(t, ast.Name) and t.id == "__all__" for t in node.targets
        )
    if isinstance(node, ast.AnnAssign):
        return isinstance(node.target, ast.Name) and node.target.id == "__all__"
    return False


def is_dead_shim(filepath: Path) -> bool:
    """True when module body only contains imports/docstring/__all__."""
    try:
        tree = ast.parse(filepath.read_text(encoding="utf-8"), filename=str(filepath))
    except (SyntaxError, UnicodeDecodeError):
        return False

    if not tree.body:
        return False

    for node in tree.body:
        if _is_docstring_expr(node):
            continue
        if isinstance(node, ast.Import | ast.ImportFrom):
            continue
        if _is_all_assignment(node):
            continue
        return False
    return True


def _staged_py_files() -> list[Path] | None:
    """If VIBEGUARD_STAGED_FILES is set, return only staged .py files."""
    staged_path = os.environ.get("VIBEGUARD_STAGED_FILES", "")
    if not staged_path or not Path(staged_path).is_file():
        return None
    files = []
    for line in Path(staged_path).read_text().splitlines():
        line = line.strip()
        if line and line.endswith(".py"):
            files.append(Path(line))
    return files


def main() -> int:
    strict = "--strict" in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    target_dir = Path(args[0]) if args else DEFAULT_TARGET_DIR

    # Pre-commit mode: only check staged files
    staged = _staged_py_files()
    if staged is not None:
        py_files_to_check = [f for f in staged if f.is_file() and f.name not in SKIP_FILES]
    else:
        if not target_dir.exists():
            print(f"[ERR] Target directory not found: {target_dir}")
            return 1
        py_files_to_check = [
            f for f in sorted(target_dir.rglob("*.py"))
            if not any(d in SKIP_DIRS for d in f.relative_to(target_dir).parts)
            and f.name not in SKIP_FILES
        ]

    allowlist = load_allowlist(target_dir) if target_dir.exists() else set()
    shims: list[str] = []

    for py_file in py_files_to_check:
        try:
            rel_path = str(py_file.relative_to(target_dir))
        except ValueError:
            rel_path = str(py_file)
        if rel_path in allowlist:
            continue

        if is_dead_shim(py_file):
            shims.append(rel_path)

    if not shims:
        print("No dead shims found")
        return 0

    for s in shims:
        print(f"[PY-13] {s} — dead shell file (only re-export, no original definition)")

    print(f"\nTotal: {len(shims)} dead shim(s)")

    if strict:
        print("\n--strict mode: dead shims found, exit code 1")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())

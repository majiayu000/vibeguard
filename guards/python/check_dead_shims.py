#!/usr/bin/env python3
"""死壳检测器 — 检测只含 re-export 的 Python 兼容壳文件。

扫描项目目录，找出仅包含 import 语句、docstring 和 __all__ 赋值的文件，
这些文件通常是向后兼容壳，应当直接删除。

使用方法：
    python3 check_dead_shims.py [target_dir]
    python3 check_dead_shims.py [target_dir] --strict  # 有死壳则退出码 1
"""

import ast
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


def main() -> int:
    strict = "--strict" in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    target_dir = Path(args[0]) if args else DEFAULT_TARGET_DIR

    if not target_dir.exists():
        print(f"[ERR] Target directory not found: {target_dir}")
        return 1

    allowlist = load_allowlist(target_dir)
    shims: list[str] = []

    for py_file in sorted(target_dir.rglob("*.py")):
        parts = py_file.relative_to(target_dir).parts
        if any(d in SKIP_DIRS for d in parts):
            continue
        if py_file.name in SKIP_FILES:
            continue

        rel_path = str(py_file.relative_to(target_dir))
        if rel_path in allowlist:
            continue

        if is_dead_shim(py_file):
            shims.append(rel_path)

    if not shims:
        print("No dead shims found")
        return 0

    for s in shims:
        print(f"[PY-13] {s} — 死壳文件（仅含 re-export，无原创定义）")

    print(f"\nTotal: {len(shims)} dead shim(s)")

    if strict:
        print("\n--strict mode: dead shims found, exit code 1")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())

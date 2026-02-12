#!/usr/bin/env python3
"""通用重复定义检测器 — 检测 Protocol、类、函数重复。

从 VibeGuard 框架泛化，扫描项目目录找出：
1. 重复的 Protocol 定义（跨文件同名接口）
2. 重复的类名（跨文件同名类）
3. 重复的模块级函数（跨模块同名顶层函数）

配置方式：
  修改下方 CONFIG 部分的目录和豁免列表。

使用方法：
    python check_duplicates.py [target_dir]
    python check_duplicates.py --strict    # 有重复 Protocol 则退出码 1
"""

import re
import sys
from collections import defaultdict
from pathlib import Path

# ---------------------------------------------------------------------------
# CONFIG — 根据项目需求修改以下配置
# ---------------------------------------------------------------------------

# 默认扫描目录（从命令行参数获取，或使用默认值）
DEFAULT_TARGET_DIR = Path(__file__).resolve().parent.parent / "app"

# 跳过的目录和文件
SKIP_DIRS: set[str] = {"__pycache__", ".git", "archive", "tests"}
SKIP_FILES: set[str] = {"__init__.py"}

# Protocol 允许同名的豁免列表
PROTOCOL_ALLOWLIST: set[str] = set()

# 类名允许重复的豁免列表
CLASS_ALLOWLIST: set[str] = set()

# 模块级函数允许同名的豁免列表（标准模式函数名）
FUNC_ALLOWLIST: set[str] = {
    "configure",
    "setup",
    "teardown",
    "main",
}


# ---------------------------------------------------------------------------
# 检测逻辑
# ---------------------------------------------------------------------------

MODULE_CLASS_RE = re.compile(r"^class\s+(\w+)\s*[\(:]")
MODULE_FUNC_RE = re.compile(r"^def\s+(\w+)\s*\(")
PROTOCOL_RE = re.compile(r"^class\s+(\w+)\s*\(\s*Protocol\s*\)")


def collect_definitions(target_dir: Path) -> tuple[
    dict[str, list[str]],
    dict[str, list[str]],
    dict[str, list[str]],
]:
    classes: dict[str, list[str]] = defaultdict(list)
    protocols: dict[str, list[str]] = defaultdict(list)
    functions: dict[str, list[str]] = defaultdict(list)

    for py_file in sorted(target_dir.rglob("*.py")):
        parts = py_file.relative_to(target_dir).parts
        if any(d in SKIP_DIRS for d in parts):
            continue
        if py_file.name in SKIP_FILES:
            continue

        rel_path = str(py_file.relative_to(target_dir))

        try:
            text = py_file.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue

        for line in text.splitlines():
            if line.startswith((" ", "\t")):
                continue

            proto_match = PROTOCOL_RE.match(line)
            if proto_match:
                name = proto_match.group(1)
                protocols[name].append(rel_path)
                classes[name].append(rel_path)
                continue

            cls_match = MODULE_CLASS_RE.match(line)
            if cls_match:
                name = cls_match.group(1)
                classes[name].append(rel_path)
                continue

            func_match = MODULE_FUNC_RE.match(line)
            if func_match:
                name = func_match.group(1)
                if not name.startswith("_"):
                    functions[name].append(rel_path)

    return classes, protocols, functions


def find_duplicates(
    definitions: dict[str, list[str]],
    allowlist: set[str],
) -> dict[str, list[str]]:
    dupes = {}
    for name, paths in sorted(definitions.items()):
        if name in allowlist:
            continue
        unique_paths = list(dict.fromkeys(paths))
        if len(unique_paths) > 1:
            dupes[name] = unique_paths
    return dupes


def main() -> int:
    strict = "--strict" in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    target_dir = Path(args[0]) if args else DEFAULT_TARGET_DIR

    if not target_dir.exists():
        print(f"[ERR] Target directory not found: {target_dir}")
        return 1

    classes, protocols, functions = collect_definitions(target_dir)

    dup_protocols = find_duplicates(protocols, PROTOCOL_ALLOWLIST)
    dup_classes = find_duplicates(classes, CLASS_ALLOWLIST)
    dup_functions = find_duplicates(functions, FUNC_ALLOWLIST)

    has_protocol_issues = bool(dup_protocols)

    if dup_protocols:
        print("\n=== Duplicate Protocol Definitions ===")
        print("(Shared Protocols should be in core/interfaces/)\n")
        for name, paths in dup_protocols.items():
            print(f"  {name}:")
            for p in paths:
                print(f"    - {p}")

    if dup_classes:
        print("\n=== Duplicate Class Names ===")
        print("(May indicate copy-paste; consider merging)\n")
        for name, paths in dup_classes.items():
            print(f"  {name}:")
            for p in paths:
                print(f"    - {p}")

    if dup_functions:
        print("\n=== Duplicate Module-Level Functions ===")
        print("(Same-named top-level functions may need shared module)\n")
        for name, paths in dup_functions.items():
            print(f"  {name}:")
            for p in paths:
                print(f"    - {p}")

    if not dup_protocols and not dup_classes and not dup_functions:
        print("No duplicate definitions found")
        return 0

    total = len(dup_protocols) + len(dup_classes) + len(dup_functions)
    print(f"\nTotal: {total} groups of duplicates")

    if strict and has_protocol_issues:
        print("\n--strict mode: duplicate Protocols found, exit code 1")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())

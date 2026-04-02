#!/usr/bin/env python3
"""Universal duplicate definition detector — detects Protocol, class, function duplication.

Generalizing from the VibeGuard framework, scan the project directory to find:
1. Duplicate Protocol definitions (interfaces with the same name across files)
2. Duplicate class names (classes with the same name across files)
3. Duplicate module-level functions (top-level functions with the same name across modules)

Configuration method:
  Modify the directory and exemption list in the CONFIG section below.

How to use:
    python check_duplicates.py [target_dir]
    python check_duplicates.py --strict # If there are duplicate protocols, exit code 1
"""

import re
import sys
from collections import defaultdict
from pathlib import Path

# ---------------------------------------------------------------------------
# CONFIG — Modify the following configuration according to project needs
# ---------------------------------------------------------------------------

#Default scan directory (obtained from command line parameters, or use default value)
DEFAULT_TARGET_DIR = Path(__file__).resolve().parent.parent / "app"

# Directories and files to skip
SKIP_DIRS: set[str] = {"__pycache__", ".git", "archive", "tests"}
SKIP_FILES: set[str] = {"__init__.py"}

# Protocol allows exemption lists with the same name
PROTOCOL_ALLOWLIST: set[str] = set()

# Exemption list that allows duplicate class names
CLASS_ALLOWLIST: set[str] = set()

# Module-level functions allow exemption lists with the same name (standard mode function names)
FUNC_ALLOWLIST: set[str] = {
    "configure",
    "setup",
    "teardown",
    "main",
}


# ---------------------------------------------------------------------------
# Detection logic
# ---------------------------------------------------------------------------

MODULE_CLASS_RE = re.compile(r"^class\s+(\w+)\s*[\(:]")
MODULE_FUNC_RE = re.compile(r"^def\s+(\w+)\s*\(")
PROTOCOL_RE = re.compile(r"^class\s+(\w+)\s*\(\s*(?:typing(?:_extensions)?\.)?Protocol\s*\)")


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

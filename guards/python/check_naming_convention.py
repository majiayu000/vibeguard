#!/usr/bin/env python3
"""Universal Python naming convention checker — detects camelCase mixins.

Generalize from the VibeGuard framework to ensure consistent use of snake_case within Python.

Configuration method:
  Modify the known key names and exemption paths in the CONFIG section below.

How to use:
    python check_naming_convention.py [path]
    python check_naming_convention.py app/
    python check_naming_convention.py # Check app/ directory by default
"""

import os
import re
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# CONFIG — Modify the following configuration according to project needs
# ---------------------------------------------------------------------------

# Known camelCase key mappings (add the actual key names used in your project)
KNOWN_CAMEL_KEYS: dict[str, str] = {
    # Common key name example
    "propertyName": "property_name",
    "firstName": "first_name",
    "lastName": "last_name",
    "createdAt": "created_at",
    "updatedAt": "updated_at",
    "userId": "user_id",
    "imageUrl": "image_url",
    "fileId": "file_id",
    "jobId": "job_id",
    "pageCount": "page_count",
    #Add the specific key name of your project here...
}

# Allow camelCase files/paths
ALLOWED_PATHS: set[str] = {
    "tests/",
    "scripts/",  # Tool scripts that define camelCase mapping tables
    #Add here the path that allows camelCase in your project...
    # For example, API schema files, front-end data construction files, etc.
}

# Allow line context using camelCase (regular mode)
ALLOWED_PATTERNS: list[str] = [
    r'alias_generator\s*=',
    r'by_alias\s*=\s*True',
    r'to_camel\(',
    r'camelize_obj\(',
    r'Field\(.+alias=',
    r'return\s*\{',
    r'\.model_dump\(',
    r'>>>\s*',
    r'#\s*Example:',
]


# ---------------------------------------------------------------------------
# Check logic
# ---------------------------------------------------------------------------

def is_allowed_file(filepath: Path) -> bool:
    filepath_str = str(filepath)
    return any(allowed in filepath_str for allowed in ALLOWED_PATHS)


def is_allowed_context(line: str) -> bool:
    return any(re.search(pattern, line) for pattern in ALLOWED_PATTERNS)


def check_file(filepath: Path) -> list[tuple[int, str, str, str]]:
    """Check for naming issues in individual files.

    Returns:
        List of (line_number, line_content, camel_key, snake_key)
    """
    if is_allowed_file(filepath):
        return []

    issues = []
    try:
        content = filepath.read_text(encoding="utf-8")
    except Exception as e:
        print(f"  Warning: Failed to read {filepath}: {e}", file=sys.stderr)
        return []

    in_docstring = False
    docstring_delimiter = None

    for line_num, line in enumerate(content.splitlines(), 1):
        stripped = line.lstrip()

        if not in_docstring:
            if stripped.startswith('"""') or stripped.startswith("'''"):
                docstring_delimiter = stripped[:3]
                rest = stripped[3:]
                if docstring_delimiter in rest:
                    continue
                in_docstring = True
                continue
        else:
            if docstring_delimiter in line:
                in_docstring = False
                docstring_delimiter = None
            continue

        if stripped.startswith("#"):
            continue

        if is_allowed_context(line):
            continue

        for camel_key, snake_key in KNOWN_CAMEL_KEYS.items():
            patterns = [
                rf'\.get\(\s*["\']{ camel_key }["\']',
                rf'\[\s*["\']{ camel_key }["\']\s*\]',
                rf'["\']{ camel_key }["\']\s*:',
            ]
            for pattern in patterns:
                if re.search(pattern, line):
                    issues.append((line_num, line.strip(), camel_key, snake_key))
                    break

    return issues


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


def main() -> None:
    staged = _staged_py_files()
    if staged is not None:
        py_files = [f for f in staged if f.is_file()]
    elif len(sys.argv) > 1:
        paths = [Path(p) for p in sys.argv[1:]]
        py_files = []
        for path in paths:
            if path.is_file() and path.suffix == ".py":
                py_files.append(path)
            elif path.is_dir():
                py_files.extend(
                    f for f in path.rglob("*.py") if "__pycache__" not in str(f)
                )
    else:
        py_files = [
            f for f in Path("app").rglob("*.py") if "__pycache__" not in str(f)
        ]

    all_issues: dict[Path, list] = {}

    for py_file in py_files:
        issues = check_file(py_file)
        if issues:
            all_issues[py_file] = issues

    if all_issues:
        print("=" * 70)
        print("camelCase naming issues found")
        print("=" * 70)
        print()

        total_issues = 0
        for filepath, issues in sorted(all_issues.items()):
            print(f"  {filepath}")
            for line_num, line, camel_key, snake_key in issues:
                total_issues += 1
                print(f"   Line {line_num}: '{camel_key}' -> use '{snake_key}'")
                print(f"      {line[:80]}{'...' if len(line) > 80 else ''}")
            print()

        print("=" * 70)
        print(f"Total: {total_issues} issues")
        print()
        print("Fix suggestions:")
        print("  1. Use snakeize_obj() at data entry points")
        print("  2. Use snake_case internally in Python")
        print("  3. Use camelize_obj() at API boundaries")
        print("=" * 70)
        sys.exit(1)
    else:
        print("Naming convention check passed")
        sys.exit(0)


if __name__ == "__main__":
    main()

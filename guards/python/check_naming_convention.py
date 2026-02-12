#!/usr/bin/env python3
"""通用 Python 命名规范检查器 — 检测 camelCase 混用。

从 VibeGuard 框架泛化，确保 Python 内部统一使用 snake_case。

配置方式：
  修改下方 CONFIG 部分的已知键名和豁免路径。

使用方法：
    python check_naming_convention.py [path]
    python check_naming_convention.py app/
    python check_naming_convention.py  # 默认检查 app/ 目录
"""

import re
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# CONFIG — 根据项目需求修改以下配置
# ---------------------------------------------------------------------------

# 已知的 camelCase 键名映射（在你的项目中添加实际使用的键名）
KNOWN_CAMEL_KEYS: dict[str, str] = {
    # 通用键名示例
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
    # 在此添加你项目的具体键名...
}

# 允许使用 camelCase 的文件/路径
ALLOWED_PATHS: set[str] = {
    "tests/",
    # 在此添加你项目中允许 camelCase 的路径...
    # 例如 API schema 文件、前端数据构建文件等
}

# 允许使用 camelCase 的行上下文（正则模式）
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
# 检查逻辑
# ---------------------------------------------------------------------------

def is_allowed_file(filepath: Path) -> bool:
    filepath_str = str(filepath)
    return any(allowed in filepath_str for allowed in ALLOWED_PATHS)


def is_allowed_context(line: str) -> bool:
    return any(re.search(pattern, line) for pattern in ALLOWED_PATTERNS)


def check_file(filepath: Path) -> list[tuple[int, str, str, str]]:
    """检查单个文件中的命名问题。

    Returns:
        List of (line_number, line_content, camel_key, snake_key)
    """
    if is_allowed_file(filepath):
        return []

    issues = []
    try:
        content = filepath.read_text(encoding="utf-8")
    except Exception:
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


def main() -> None:
    if len(sys.argv) > 1:
        paths = [Path(p) for p in sys.argv[1:]]
    else:
        paths = [Path("app")]

    all_issues: dict[Path, list] = {}

    for path in paths:
        if path.is_file() and path.suffix == ".py":
            issues = check_file(path)
            if issues:
                all_issues[path] = issues
        elif path.is_dir():
            for py_file in path.rglob("*.py"):
                if "__pycache__" in str(py_file):
                    continue
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

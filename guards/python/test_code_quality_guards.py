"""通用架构守卫 — 防止 AI vibe-coding 回归。

从 VibeGuard 框架泛化，检测五种常见 LLM 代码生成失效模式：
1. 静默吞异常（except without logging）
2. Any 类型公开方法签名（facade/application 层）
3. 纯 re-export shim 文件
4. 跨模块私有属性访问
5. 重复 Protocol 定义

配置方式：
  在 conftest.py 中设置以下变量，或在 pyproject.toml 中配置。
  默认扫描 app/ 目录。

使用方法：
  1. 复制此文件到项目的 tests/architecture/ 目录
  2. 修改下方 CONFIG 部分的路径配置
  3. 运行 pytest tests/architecture/test_code_quality_guards.py -v
"""

from __future__ import annotations

import ast
import re
from pathlib import Path

# ---------------------------------------------------------------------------
# CONFIG — 根据项目结构修改以下路径
# ---------------------------------------------------------------------------

# 项目根目录（从本文件位置推导，假设 tests/architecture/ 下）
PROJECT_ROOT = Path(__file__).resolve().parents[2]

# 源代码根目录
APP_ROOT = PROJECT_ROOT / "app"

# 需要扫描的 application 层目录
APPLICATION_DIRS: list[Path] = [
    # 示例：取消注释并修改为你的项目结构
    # APP_ROOT / "contexts" / "generation" / "application",
    # APP_ROOT / "contexts" / "ingestion" / "application",
]

# 需要扫描的 workflow 层目录
WORKFLOW_DIRS: list[Path] = [
    # 示例：
    # APP_ROOT / "contexts" / "generation" / "workflows",
]

# Facade 文件所在目录（默认同 APPLICATION_DIRS）
FACADE_DIRS: list[Path] = APPLICATION_DIRS

# API Schema 目录（检测 re-export shim）
SCHEMAS_DIR: Path = APP_ROOT / "api" / "v1" / "schemas"

# 私有属性访问豁免列表（已知技术债）
PRIVATE_ACCESS_ALLOWLIST: set[str] = set()

# Protocol 重复豁免列表
DUPLICATE_PROTOCOL_ALLOWLIST: set[str] = set()

# 跳过的目录名
SKIP_DIRS: set[str] = {"__pycache__", "archive", "tests"}


# ---------------------------------------------------------------------------
# 自动发现：如果未手动配置，自动扫描 APP_ROOT 下的目录
# ---------------------------------------------------------------------------

def _auto_discover_dirs() -> None:
    global APPLICATION_DIRS, WORKFLOW_DIRS, FACADE_DIRS
    if APPLICATION_DIRS or WORKFLOW_DIRS:
        return  # 已手动配置，跳过自动发现

    if not APP_ROOT.exists():
        return

    for path in APP_ROOT.rglob("*"):
        if not path.is_dir():
            continue
        if any(skip in path.parts for skip in SKIP_DIRS):
            continue
        if path.name == "application":
            APPLICATION_DIRS.append(path)
        elif path.name == "workflows":
            WORKFLOW_DIRS.append(path)

    FACADE_DIRS = APPLICATION_DIRS


_auto_discover_dirs()


# ---------------------------------------------------------------------------
# 1. 静默吞异常
# ---------------------------------------------------------------------------

def _is_broad_except(handler: ast.ExceptHandler) -> bool:
    """True if handler catches Exception or bare except."""
    if handler.type is None:
        return True
    if isinstance(handler.type, ast.Name) and handler.type.id == "Exception":
        return True
    return False


def _handler_has_logging_or_raise(handler: ast.ExceptHandler) -> bool:
    """True if the except body contains a raise, or a logger/logging call."""
    for child in ast.walk(handler):
        if isinstance(child, ast.Raise):
            return True
        if isinstance(child, ast.Call):
            func = child.func
            if isinstance(func, ast.Attribute) and func.attr in (
                "exception", "error", "warning", "warn",
                "info", "debug", "critical",
            ):
                return True
    return False


def _silent_broad_excepts(filepath: Path) -> list[str]:
    """Return 'file:line' for broad except blocks that silently swallow errors."""
    violations: list[str] = []
    try:
        tree = ast.parse(filepath.read_text(encoding="utf-8"), filename=str(filepath))
    except SyntaxError:
        return violations

    for node in ast.walk(tree):
        if not isinstance(node, ast.ExceptHandler):
            continue
        if not _is_broad_except(node):
            continue
        if _handler_has_logging_or_raise(node):
            continue
        try:
            rel = filepath.relative_to(PROJECT_ROOT)
        except ValueError:
            rel = filepath
        violations.append(f"{rel}:{node.lineno}")
    return violations


def test_no_silent_exception_swallowing() -> None:
    """Broad except blocks must log or re-raise."""
    violations: list[str] = []
    for directory in APPLICATION_DIRS + WORKFLOW_DIRS:
        if not directory.exists():
            continue
        for py_file in directory.rglob("*.py"):
            violations.extend(_silent_broad_excepts(py_file))
    assert not violations, (
        "Silent exception swallowing detected:\n" + "\n".join(violations)
    )


# ---------------------------------------------------------------------------
# 2. Any 类型公开方法签名
# ---------------------------------------------------------------------------

def _is_any(annotation: ast.expr | None) -> bool:
    if annotation is None:
        return False
    if isinstance(annotation, ast.Constant) and annotation.value == "Any":
        return True
    if isinstance(annotation, ast.Name) and annotation.id == "Any":
        return True
    if isinstance(annotation, ast.Attribute) and annotation.attr == "Any":
        return True
    return False


def _any_typed_public_methods(filepath: Path) -> list[str]:
    """Return violations for public methods with Any in param/return annotations."""
    violations: list[str] = []
    try:
        tree = ast.parse(filepath.read_text(encoding="utf-8"), filename=str(filepath))
    except SyntaxError:
        return violations

    # Protocol 类的方法豁免
    protocol_ranges: list[tuple[int, int]] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.ClassDef):
            for base in node.bases:
                base_name = base.id if isinstance(base, ast.Name) else getattr(base, "attr", "")
                if base_name == "Protocol":
                    protocol_ranges.append((node.lineno, node.end_lineno or node.lineno))

    def _in_protocol(lineno: int) -> bool:
        return any(start <= lineno <= end for start, end in protocol_ranges)

    for node in ast.walk(tree):
        if not isinstance(node, ast.FunctionDef | ast.AsyncFunctionDef):
            continue
        if node.name.startswith("_"):
            continue
        if _in_protocol(node.lineno):
            continue

        for arg in node.args.args:
            if arg.arg == "self":
                continue
            if _is_any(arg.annotation):
                try:
                    rel = filepath.relative_to(PROJECT_ROOT)
                except ValueError:
                    rel = filepath
                violations.append(f"{rel}:{arg.lineno}: param '{arg.arg}' typed as Any")

        if _is_any(node.returns):
            try:
                rel = filepath.relative_to(PROJECT_ROOT)
            except ValueError:
                rel = filepath
            violations.append(f"{rel}:{node.lineno}: return typed as Any")
    return violations


def test_no_any_in_facade_signatures() -> None:
    """Facade public methods must not use bare Any for params or return types."""
    violations: list[str] = []
    for directory in FACADE_DIRS:
        if not directory.exists():
            continue
        for py_file in directory.rglob("*facade*.py"):
            violations.extend(_any_typed_public_methods(py_file))
    assert not violations, (
        "Any-typed public method signatures in facade files:\n" + "\n".join(violations)
    )


# ---------------------------------------------------------------------------
# 3. Re-export shim 检测
# ---------------------------------------------------------------------------

def _is_docstring_expr(node: ast.stmt) -> bool:
    return isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str)


def _is_all_assignment(node: ast.stmt) -> bool:
    if isinstance(node, ast.Assign):
        return bool(node.targets) and all(
            isinstance(target, ast.Name) and target.id == "__all__" for target in node.targets
        )
    if isinstance(node, ast.AnnAssign):
        return isinstance(node.target, ast.Name) and node.target.id == "__all__"
    return False


def _is_pure_reexport_shim(filepath: Path) -> bool:
    """True when module body only contains imports/docstring/__all__."""
    try:
        tree = ast.parse(filepath.read_text(encoding="utf-8"), filename=str(filepath))
    except SyntaxError:
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


def test_no_reexport_shims_in_schemas() -> None:
    """API schema files must contain actual definitions, not just re-exports."""
    if not SCHEMAS_DIR.exists():
        return
    violations: list[str] = []
    for py_file in SCHEMAS_DIR.glob("*.py"):
        if py_file.name == "__init__.py":
            continue
        if _is_pure_reexport_shim(py_file):
            try:
                rel = py_file.relative_to(PROJECT_ROOT)
            except ValueError:
                rel = py_file
            violations.append(f"{rel} is a pure re-export shim")
    assert not violations, (
        "Pure re-export shim files detected:\n" + "\n".join(violations)
    )


# ---------------------------------------------------------------------------
# 4. 跨模块私有属性访问
# ---------------------------------------------------------------------------

_PRIVATE_ACCESS_RE = re.compile(r"\b\w+\._[a-z]\w*")
_FALSE_POSITIVE_RE = re.compile(
    r"self(?:\.\w+)*\._"
    r"|cls\._"
    r"|super\(\)\.__"
    r"|\.__\w+__"
    r"|\._replace\("
    r"|#\s*type:\s*ignore"
    r"|from \._"
)


def test_no_cross_module_private_access() -> None:
    """Application/workflow layers must not access other modules' _private attributes."""
    violations: list[str] = []
    for directory in APPLICATION_DIRS + WORKFLOW_DIRS:
        if not directory.exists():
            continue
        for py_file in directory.rglob("*.py"):
            source = py_file.read_text(encoding="utf-8")
            for lineno, line in enumerate(source.splitlines(), 1):
                stripped = line.strip()
                if stripped.startswith("#"):
                    continue
                if not _PRIVATE_ACCESS_RE.search(line):
                    continue
                cleaned = _FALSE_POSITIVE_RE.sub("", line)
                if _PRIVATE_ACCESS_RE.search(cleaned):
                    try:
                        rel = py_file.relative_to(PROJECT_ROOT)
                    except ValueError:
                        rel = py_file
                    location = f"{rel}:{lineno}"
                    if location in PRIVATE_ACCESS_ALLOWLIST:
                        continue
                    violations.append(f"{location}: {stripped}")
    assert not violations, (
        "Cross-module private attribute access:\n" + "\n".join(violations)
    )


# ---------------------------------------------------------------------------
# 5. 重复 Protocol 定义
# ---------------------------------------------------------------------------

_PROTOCOL_RE_PATTERN = re.compile(
    r"^class\s+(\w+)\s*\(\s*(?:typing(?:_extensions)?\.)?Protocol\s*\)"
)


def test_no_duplicate_protocol_definitions() -> None:
    """Same-named Protocol must not be defined in multiple files."""
    from collections import defaultdict

    if not APP_ROOT.exists():
        return

    protocol_locations: dict[str, list[str]] = defaultdict(list)

    for py_file in sorted(APP_ROOT.rglob("*.py")):
        parts = py_file.relative_to(APP_ROOT).parts
        if any(d in SKIP_DIRS for d in parts):
            continue
        if py_file.name == "__init__.py":
            continue

        try:
            source = py_file.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue

        for line in source.splitlines():
            if line.startswith((" ", "\t")):
                continue
            m = _PROTOCOL_RE_PATTERN.match(line)
            if m:
                try:
                    rel = str(py_file.relative_to(PROJECT_ROOT))
                except ValueError:
                    rel = str(py_file)
                protocol_locations[m.group(1)].append(rel)

    violations: list[str] = []
    for name, paths in sorted(protocol_locations.items()):
        unique = list(dict.fromkeys(paths))
        if len(unique) > 1 and name not in DUPLICATE_PROTOCOL_ALLOWLIST:
            locations = ", ".join(unique)
            violations.append(f"{name} defined in {len(unique)} files: {locations}")

    assert not violations, (
        "Duplicate Protocol definitions detected:\n" + "\n".join(violations)
    )

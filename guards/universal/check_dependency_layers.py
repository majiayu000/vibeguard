#!/usr/bin/env python3
"""VibeGuard Guard — 依赖层方向检查

根据 .vibeguard-architecture.yaml 定义的分层架构，检测跨层引用违规。
违规时输出包含修复指令的错误信息（Golden Principle #3: 机械执行 > 文档描述）。

用法：
    python3 check_dependency_layers.py [target_dir]
    python3 check_dependency_layers.py --config path/to/.vibeguard-architecture.yaml

退出码：
    0 — 无违规
    1 — 发现违规
    2 — 配置错误
"""

import ast
import os
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    yaml = None


def load_config(target_dir: str) -> dict:
    """加载架构配置文件"""
    config_path = os.path.join(target_dir, ".vibeguard-architecture.yaml")
    if not os.path.exists(config_path):
        return {}

    if yaml is None:
        # Fallback: 简易 YAML 解析
        return _parse_yaml_simple(config_path)

    with open(config_path) as f:
        return yaml.safe_load(f) or {}


def _parse_yaml_simple(path: str) -> dict:
    """无 PyYAML 依赖的简易解析"""
    layers = []
    current_layer = None

    with open(path) as f:
        for line in f:
            stripped = line.strip()
            if stripped.startswith("- name:"):
                current_layer = {
                    "name": stripped.split(":", 1)[1].strip().strip('"\''),
                    "paths": [],
                    "allowed_deps": [],
                }
                layers.append(current_layer)
            elif current_layer and "paths:" in stripped and "[" in stripped:
                items = re.findall(r'"([^"]+)"', stripped)
                current_layer["paths"] = items
            elif current_layer and "allowed_deps:" in stripped and "[" in stripped:
                items = re.findall(r'"([^"]+)"', stripped)
                current_layer["allowed_deps"] = items

    return {"layers": layers} if layers else {}


def resolve_layer(file_path: str, layers: list[dict]) -> str | None:
    """确定文件所属层"""
    normalized = file_path.replace("\\", "/")
    for layer in layers:
        for pattern in layer.get("paths", []):
            pattern_clean = pattern.rstrip("/")
            if f"/{pattern_clean}/" in f"/{normalized}" or normalized.startswith(
                pattern_clean
            ):
                return layer["name"]
    return None


def extract_imports_python(file_path: str) -> list[str]:
    """提取 Python import 路径"""
    try:
        with open(file_path) as f:
            tree = ast.parse(f.read(), filename=file_path)
    except SyntaxError:
        return []

    imports = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                imports.append(alias.name)
        elif isinstance(node, ast.ImportFrom):
            if node.module:
                imports.append(node.module)
    return imports


def extract_imports_typescript(file_path: str) -> list[str]:
    """提取 TypeScript/JavaScript import 路径"""
    imports = []
    try:
        with open(file_path) as f:
            content = f.read()
    except (OSError, UnicodeDecodeError):
        return []

    # import ... from '...'
    for match in re.finditer(r"""(?:import|from)\s+['"]([^'"]+)['"]""", content):
        imports.append(match.group(1))
    # require('...')
    for match in re.finditer(r"""require\s*\(\s*['"]([^'"]+)['"]\s*\)""", content):
        imports.append(match.group(1))
    return imports


def extract_imports_go(file_path: str) -> list[str]:
    """提取 Go import 路径"""
    imports = []
    try:
        with open(file_path) as f:
            content = f.read()
    except (OSError, UnicodeDecodeError):
        return []

    for match in re.finditer(r'"([^"]+)"', content):
        path = match.group(1)
        if "/" in path:
            imports.append(path)
    return imports


def extract_imports_rust(file_path: str) -> list[str]:
    """提取 Rust use 路径"""
    imports = []
    try:
        with open(file_path) as f:
            content = f.read()
    except (OSError, UnicodeDecodeError):
        return []

    for match in re.finditer(r"use\s+([\w:]+)", content):
        imports.append(match.group(1))
    return imports


def import_to_layer(
    import_path: str, file_path: str, layers: list[dict]
) -> str | None:
    """将 import 路径映射到层"""
    # 相对路径 import（TypeScript/Python）
    if import_path.startswith("."):
        dir_path = os.path.dirname(file_path)
        resolved = os.path.normpath(os.path.join(dir_path, import_path))
        return resolve_layer(resolved, layers)

    # 模块名匹配
    for layer in layers:
        for pattern in layer.get("paths", []):
            pattern_clean = pattern.rstrip("/").replace("/", ".")
            dir_name = pattern.rstrip("/").split("/")[-1]
            if import_path.startswith(dir_name) or import_path.startswith(
                pattern_clean
            ):
                return layer["name"]
    return None


EXTRACTORS = {
    ".py": extract_imports_python,
    ".ts": extract_imports_typescript,
    ".tsx": extract_imports_typescript,
    ".js": extract_imports_typescript,
    ".jsx": extract_imports_typescript,
    ".go": extract_imports_go,
    ".rs": extract_imports_rust,
}

SKIP_DIRS = {
    "node_modules",
    ".git",
    "target",
    "dist",
    "build",
    "__pycache__",
    ".venv",
    "vendor",
    "tests",
    "test",
}


def check_directory(target_dir: str) -> list[dict]:
    """扫描目录检测依赖违规"""
    config = load_config(target_dir)
    layers = config.get("layers", [])
    if not layers:
        return []

    # 构建层的允许依赖映射
    allowed = {}
    for layer in layers:
        name = layer["name"]
        allowed[name] = set(layer.get("allowed_deps", []))

    violations = []

    for root, dirs, files in os.walk(target_dir):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]

        for fname in files:
            ext = os.path.splitext(fname)[1]
            if ext not in EXTRACTORS:
                continue

            file_path = os.path.join(root, fname)
            rel_path = os.path.relpath(file_path, target_dir)
            source_layer = resolve_layer(rel_path, layers)
            if source_layer is None:
                continue

            extractor = EXTRACTORS[ext]
            imports = extractor(file_path)

            for imp in imports:
                target_layer = import_to_layer(imp, rel_path, layers)
                if target_layer is None or target_layer == source_layer:
                    continue

                if target_layer not in allowed.get(source_layer, set()):
                    violations.append(
                        {
                            "file": rel_path,
                            "source_layer": source_layer,
                            "target_layer": target_layer,
                            "import": imp,
                            "allowed": sorted(allowed.get(source_layer, set())),
                        }
                    )

    return violations


def main():
    target_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    target_dir = os.path.abspath(target_dir)

    config = load_config(target_dir)
    if not config.get("layers"):
        print(
            "未找到 .vibeguard-architecture.yaml 或层定义为空。"
        )
        print(
            "创建配置: cp ${VIBEGUARD_DIR}/templates/vibeguard-architecture.yaml "
            ".vibeguard-architecture.yaml"
        )
        sys.exit(0)

    violations = check_directory(target_dir)

    if not violations:
        print("\033[32m依赖层检查通过 — 无跨层违规\033[0m")
        sys.exit(0)

    print(f"\033[31m发现 {len(violations)} 个依赖层违规:\033[0m\n")
    for v in violations:
        print(f"  {v['file']}")
        print(f"    违规: {v['source_layer']} → {v['target_layer']} (import {v['import']})")
        print(f"    允许: {v['source_layer']} → {v['allowed']}")
        print(
            f"    修复: 将 {v['import']} 的功能移到 {v['source_layer']} 层可访问的层，"
            f"或通过接口解耦"
        )
        print()

    sys.exit(1)


if __name__ == "__main__":
    main()

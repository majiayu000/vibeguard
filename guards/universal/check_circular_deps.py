#!/usr/bin/env python3
"""VibeGuard Guard — 循环依赖检测

构建模块级依赖图，检测环路。
区分硬环（直接 import）和软环（可通过接口解耦）。

用法：
    python3 check_circular_deps.py [target_dir]

退出码：
    0 — 无循环依赖
    1 — 发现循环依赖
"""

import os
import re
import sys
from collections import defaultdict
from pathlib import Path

SKIP_DIRS = {
    "node_modules",
    ".git",
    "target",
    "dist",
    "build",
    "__pycache__",
    ".venv",
    "vendor",
}

IMPORT_PATTERNS = {
    ".py": [
        re.compile(r"^\s*from\s+([\w.]+)\s+import", re.MULTILINE),
        re.compile(r"^\s*import\s+([\w.]+)", re.MULTILINE),
    ],
    ".ts": [
        re.compile(r"""(?:import|from)\s+['"](\.[^'"]+)['"]"""),
    ],
    ".tsx": [
        re.compile(r"""(?:import|from)\s+['"](\.[^'"]+)['"]"""),
    ],
    ".js": [
        re.compile(r"""(?:import|from)\s+['"](\.[^'"]+)['"]"""),
        re.compile(r"""require\s*\(\s*['"](\.[^'"]+)['"]\s*\)"""),
    ],
    ".go": [
        # Go 使用绝对路径，模块间循环由 compiler 检测，这里跳过
    ],
    ".rs": [
        re.compile(r"^\s*(?:pub\s+)?use\s+(crate::[\w:]+)", re.MULTILINE),
        re.compile(r"^\s*(?:pub\s+)?mod\s+(\w+)", re.MULTILINE),
    ],
}


def get_module_name(file_path: str, base_dir: str) -> str:
    """将文件路径转为模块名（取第一级目录作为模块）"""
    rel = os.path.relpath(file_path, base_dir)
    parts = rel.replace("\\", "/").split("/")
    # 模块 = 第一级目录（src/ 下的第二级）
    if parts[0] == "src" and len(parts) > 1:
        return parts[1]
    return parts[0]


def resolve_import_module(
    import_path: str, file_path: str, base_dir: str
) -> str | None:
    """将 import 路径解析为模块名"""
    if import_path.startswith("."):
        # 相对路径
        dir_path = os.path.dirname(file_path)
        resolved = os.path.normpath(os.path.join(dir_path, import_path))
        return get_module_name(resolved, base_dir)
    elif import_path.startswith("crate::"):
        # Rust crate 内部
        parts = import_path.replace("crate::", "").split("::")
        return parts[0] if parts else None
    else:
        # 包名 → 取第一段作为模块
        parts = import_path.split(".")
        return parts[0] if parts else None


def build_dependency_graph(target_dir: str) -> dict[str, set[str]]:
    """构建模块级依赖图"""
    graph: dict[str, set[str]] = defaultdict(set)

    for root, dirs, files in os.walk(target_dir):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]

        for fname in files:
            ext = os.path.splitext(fname)[1]
            patterns = IMPORT_PATTERNS.get(ext, [])
            if not patterns:
                continue

            file_path = os.path.join(root, fname)
            source_module = get_module_name(file_path, target_dir)

            try:
                with open(file_path) as f:
                    content = f.read()
            except (OSError, UnicodeDecodeError):
                continue

            for pattern in patterns:
                for match in pattern.finditer(content):
                    import_path = match.group(1)
                    target_module = resolve_import_module(
                        import_path, file_path, target_dir
                    )
                    if (
                        target_module
                        and target_module != source_module
                        and not target_module.startswith(".")
                    ):
                        graph[source_module].add(target_module)

    return dict(graph)


def find_cycles(graph: dict[str, set[str]]) -> list[list[str]]:
    """DFS 检测所有环路"""
    cycles = []
    visited = set()
    path = []
    path_set = set()

    def dfs(node: str):
        if node in path_set:
            cycle_start = path.index(node)
            cycle = path[cycle_start:] + [node]
            # 规范化：最小元素开头
            min_idx = cycle[:-1].index(min(cycle[:-1]))
            normalized = cycle[min_idx:-1] + cycle[min_idx : min_idx + 1]
            if normalized not in cycles:
                cycles.append(normalized)
            return

        if node in visited:
            return

        visited.add(node)
        path.append(node)
        path_set.add(node)

        for neighbor in graph.get(node, set()):
            if neighbor in graph or neighbor in path_set:
                dfs(neighbor)

        path.pop()
        path_set.discard(node)

    for node in graph:
        dfs(node)

    return cycles


def main():
    target_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    target_dir = os.path.abspath(target_dir)

    print(f"扫描目录: {target_dir}")

    graph = build_dependency_graph(target_dir)

    if not graph:
        print("\033[33m未检测到模块间依赖关系\033[0m")
        sys.exit(0)

    # 输出依赖图摘要
    print(f"模块数: {len(graph)}")
    print(f"依赖边数: {sum(len(v) for v in graph.values())}")
    print()

    cycles = find_cycles(graph)

    if not cycles:
        print("\033[32m循环依赖检查通过 — 无环路\033[0m")
        sys.exit(0)

    print(f"\033[31m发现 {len(cycles)} 个循环依赖:\033[0m\n")
    for i, cycle in enumerate(cycles, 1):
        chain = " → ".join(cycle)
        print(f"  [{i}] {chain}")

        # 判断是否可通过接口解耦
        if len(cycle) == 2:
            print(
                f"      修复: 提取 {cycle[0]} 和 {cycle[1]} 的共享接口到独立模块 "
                f"(如 core/interfaces/)"
            )
        else:
            print(
                f"      修复: 分析环路中最弱的依赖边，通过依赖注入或事件驱动解耦"
            )
        print()

    sys.exit(1)


if __name__ == "__main__":
    main()

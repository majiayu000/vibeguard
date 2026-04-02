#!/usr/bin/env python3
"""VibeGuard Guard — circular dependency detection

Build module-level dependency graphs and detect loops.
Distinguish between hard loops (direct import) and soft loops (can be decoupled through interfaces).

usage:
    python3 check_circular_deps.py [target_dir]

Exit code:
    0 — no cyclic dependencies
    1 — Circular dependencies found
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
        # Go uses absolute paths, and loops between modules are detected by the compiler and skipped here.
    ],
    ".rs": [
        re.compile(r"^\s*(?:pub\s+)?use\s+(crate::[\w:]+)", re.MULTILINE),
        re.compile(r"^\s*(?:pub\s+)?mod\s+(\w+)", re.MULTILINE),
    ],
}


def get_module_name(file_path: str, base_dir: str) -> str:
    """Convert the file path to the module name (take the first-level directory as the module)"""
    rel = os.path.relpath(file_path, base_dir)
    parts = rel.replace("\\", "/").split("/")
    #Module = first-level directory (second level under src/)
    if parts[0] == "src" and len(parts) > 1:
        return parts[1]
    return parts[0]


def resolve_import_module(
    import_path: str, file_path: str, base_dir: str
) -> str | None:
    """Resolve import path to module name"""
    if import_path.startswith("."):
        # Relative path
        dir_path = os.path.dirname(file_path)
        resolved = os.path.normpath(os.path.join(dir_path, import_path))
        return get_module_name(resolved, base_dir)
    elif import_path.startswith("crate::"):
        # Inside the Rust crate
        parts = import_path.replace("crate::", "").split("::")
        return parts[0] if parts else None
    else:
        # Package name → Take the first paragraph as the module
        parts = import_path.split(".")
        return parts[0] if parts else None


def build_dependency_graph(target_dir: str) -> dict[str, set[str]]:
    """Building a module-level dependency graph"""
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
    """DFS detects all loops"""
    cycles = []
    visited = set()
    path = []
    path_set = set()

    def dfs(node: str):
        if node in path_set:
            cycle_start = path.index(node)
            cycle = path[cycle_start:] + [node]
            #Normalization: Start with the smallest element
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

    print(f"Scan directory: {target_dir}")

    graph = build_dependency_graph(target_dir)

    if not graph:
        print("\033[33mNo inter-module dependencies detected\033[0m")
        sys.exit(0)

    # Output dependency graph summary
    print(f"Number of modules: {len(graph)}")
    print(f"Depending on the number of edges: {sum(len(v) for v in graph.values())}")
    print()

    cycles = find_cycles(graph)

    if not cycles:
        print("\033[32m circular dependency check passed - no loop\033[0m")
        sys.exit(0)

    print(f"\033[31m Found {len(cycles)} cyclic dependencies:\033[0m\n")
    for i, cycle in enumerate(cycles, 1):
        chain = " → ".join(cycle)
        print(f"  [{i}] {chain}")

        # Determine whether it can be decoupled through the interface
        if len(cycle) == 2:
            print(
                f" Fix: Extract shared interfaces of {cycle[0]} and {cycle[1]} to independent modules"
                f"(such as core/interfaces/)"
            )
        else:
            print(
                f" Fix: Analyze the weakest dependency edge in the loop, via dependency injection or event-driven decoupling"
            )
        print()

    sys.exit(1)


if __name__ == "__main__":
    main()

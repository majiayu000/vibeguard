#!/usr/bin/env bash
# VibeGuard CI: 校验 Rust guards 接线完整性（实现 -> MCP -> 文档）
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TOOLS_TS="${REPO_DIR}/mcp-server/src/tools.ts"
INDEX_TS="${REPO_DIR}/mcp-server/src/index.ts"
README_MD="${REPO_DIR}/README.md"
RUST_GUARDS_DIR="${REPO_DIR}/guards/rust"

python3 - "$TOOLS_TS" "$INDEX_TS" "$README_MD" "$RUST_GUARDS_DIR" <<'PY'
import re
import sys
from pathlib import Path


def fail(msg: str) -> None:
    print(f"FAIL: {msg}")
    raise SystemExit(1)


tools_path = Path(sys.argv[1])
index_path = Path(sys.argv[2])
readme_path = Path(sys.argv[3])
guards_dir = Path(sys.argv[4])

tools_text = tools_path.read_text(encoding="utf-8")
index_text = index_path.read_text(encoding="utf-8")
readme_text = readme_path.read_text(encoding="utf-8")

# 1) 从 tools.ts 提取 rust guard 键名和对应脚本
rust_block_match = re.search(r"rust:\s*\{([\s\S]*?)\n\s*\},\n\s*typescript:", tools_text)
if not rust_block_match:
    fail("tools.ts 未找到 GUARD_REGISTRY.rust 定义块")
rust_block = rust_block_match.group(1)

guard_name_matches = re.findall(r"^\s{4}([a-z_][a-z0-9_]*)\s*:\s*\{", rust_block, re.M)
if not guard_name_matches:
    fail("未解析到 Rust guard 名称")
rust_guard_names = sorted(set(guard_name_matches))

script_matches = re.findall(r'"rust",\s*"([^"]+\.sh)"\)', rust_block)
if not script_matches:
    fail("未解析到 Rust guard 脚本引用")
rust_guard_scripts_from_tools = sorted(set(script_matches))

# 2) 文件系统中的 Rust guard 脚本
fs_scripts = sorted(
    p.name for p in guards_dir.glob("*.sh") if p.name != "common.sh"
)
if not fs_scripts:
    fail("guards/rust/ 下未找到 guard 脚本")

# 3) tools.ts 中脚本引用必须存在于文件系统
missing_in_fs = sorted(set(rust_guard_scripts_from_tools) - set(fs_scripts))
if missing_in_fs:
    print("FAIL: tools.ts 引用了不存在的 Rust guard 脚本")
    for name in missing_in_fs:
        print(f"  - {name}")
    raise SystemExit(1)

# 4) 文件系统中 guard 脚本必须全部接入 tools.ts（避免“实现了但没接线”）
missing_in_tools = sorted(set(fs_scripts) - set(rust_guard_scripts_from_tools))
if missing_in_tools:
    print("FAIL: 存在未接入 MCP 的 Rust guard 脚本")
    for name in missing_in_tools:
        print(f"  - {name}")
    raise SystemExit(1)

# 5) index.ts 文案里 rust guard 名称应覆盖 registry 全量
desc_match = re.search(r"rust:\s*([^；\"]+)", index_text)
if not desc_match:
    fail("index.ts guard 描述中未找到 rust guard 列表")
index_rust_guards = {
    x.strip()
    for x in desc_match.group(1).split("/")
    if x.strip()
}
missing_in_index = sorted(set(rust_guard_names) - index_rust_guards)
if missing_in_index:
    print("FAIL: index.ts 描述缺少 Rust guard 名称")
    for name in missing_in_index:
        print(f"  - {name}")
    raise SystemExit(1)

# 6) README Rust 守卫命令清单应覆盖脚本（可发现性）
readme_rust_cmds = set(re.findall(r"guards/rust/(check_[a-z0-9_]+\.sh)", readme_text))
missing_in_readme = sorted(set(fs_scripts) - readme_rust_cmds)
if missing_in_readme:
    print("FAIL: README Rust guard 清单缺少脚本")
    for name in missing_in_readme:
        print(f"  - {name}")
    raise SystemExit(1)

print("OK: Rust guard scripts wired in MCP registry")
print("OK: Rust guard names synced in index.ts")
print("OK: Rust guard scripts documented in README")
print("Wiring contract validation passed.")
PY

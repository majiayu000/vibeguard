#!/usr/bin/env bash
# VibeGuard CI: 校验 MCP 配置合同（schema/runtime/docs）一致性
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
INDEX_TS="${REPO_DIR}/mcp-server/src/index.ts"
TOOLS_TS="${REPO_DIR}/mcp-server/src/tools.ts"
DETECTOR_TS="${REPO_DIR}/mcp-server/src/detector.ts"
README_MD="${REPO_DIR}/README.md"

python3 - "$INDEX_TS" "$TOOLS_TS" "$DETECTOR_TS" "$README_MD" <<'PY'
import ast
import re
import sys
from pathlib import Path


def die(msg: str) -> None:
    print(f"FAIL: {msg}")
    raise SystemExit(1)


def extract_const_block(text: str, const_name: str) -> str:
    pattern = rf"const\s+{re.escape(const_name)}\b[\s\S]*?\n\}};"
    m = re.search(pattern, text)
    if not m:
        die(f"未找到常量定义块: {const_name}")
    return m.group(0)


def top_level_keys_from_block(block: str) -> list[str]:
    # 依赖 Prettier 风格：顶层 key 缩进 2 空格，嵌套 key 缩进 >=4 空格
    return re.findall(r"^  ([A-Za-z_][A-Za-z0-9_]*)\s*:", block, re.M)


def parse_language_enum(index_text: str) -> list[str]:
    m = re.search(r"language:\s*z\.enum\(\[(.*?)\]\)", index_text, re.S)
    if not m:
        die("index.ts 未找到 guard_check language z.enum")
    raw = "[" + m.group(1) + "]"
    try:
        values = ast.literal_eval(raw)
    except Exception as exc:  # pragma: no cover - defensive
        die(f"language enum 解析失败: {exc}")
    if not isinstance(values, list) or not all(isinstance(v, str) for v in values):
        die("language enum 不是字符串列表")
    return values


def parse_readme_guard_languages(readme_text: str) -> list[str]:
    m = re.search(r"`?guard_check`?\s*支持语言[:：]\s*([^\n]+)", readme_text)
    if not m:
        die("README 缺少 guard_check 支持语言说明")
    return re.findall(r"[a-z]+", m.group(1))


index_text = Path(sys.argv[1]).read_text(encoding="utf-8")
tools_text = Path(sys.argv[2]).read_text(encoding="utf-8")
detector_text = Path(sys.argv[3]).read_text(encoding="utf-8")
readme_text = Path(sys.argv[4]).read_text(encoding="utf-8")

enum_langs = parse_language_enum(index_text)
if "auto" not in enum_langs:
    die("language enum 必须包含 auto")
enum_langs_no_auto = [x for x in enum_langs if x != "auto"]

registry_block = extract_const_block(tools_text, "GUARD_REGISTRY")
registry_langs = top_level_keys_from_block(registry_block)

marker_block = extract_const_block(detector_text, "LANGUAGE_MARKERS")
detector_marker_langs = top_level_keys_from_block(marker_block)
detector_langs = list(detector_marker_langs)
if 'languages.push("javascript")' in detector_text:
    detector_langs.append("javascript")

readme_langs = parse_readme_guard_languages(readme_text)

ok = True

if set(enum_langs_no_auto) != set(registry_langs):
    print("FAIL: index.ts language enum 与 tools.ts GUARD_REGISTRY 不一致")
    print(f"  enum(no_auto): {sorted(set(enum_langs_no_auto))}")
    print(f"  registry:      {sorted(set(registry_langs))}")
    ok = False
else:
    print(f"OK: enum/runtime 一致 -> {', '.join(enum_langs_no_auto)}")

missing_runtime = sorted(set(detector_langs) - set(registry_langs))
if missing_runtime:
    print("FAIL: detector.ts 检测到的语言在 GUARD_REGISTRY 中缺失")
    print(f"  missing: {', '.join(missing_runtime)}")
    ok = False
else:
    print(f"OK: detector/runtime 一致 -> {', '.join(detector_langs)}")

if set(readme_langs) != set(enum_langs):
    print("FAIL: README guard_check 支持语言与 index.ts schema 不一致")
    print(f"  README: {sorted(set(readme_langs))}")
    print(f"  schema: {sorted(set(enum_langs))}")
    ok = False
else:
    print(f"OK: docs/schema 一致 -> {', '.join(readme_langs)}")

if not ok:
    raise SystemExit(1)

print("Contract validation passed.")
PY

#!/usr/bin/env bash
# VibeGuard TypeScript Guard — [TS-03] console 残留检测
#
# 使用 ast-grep 做 AST 级别检测，仅匹配实际调用表达式，跳过注释和字符串。
# 与 post-edit-guard 的实时检测互补，这个脚本做项目级全量扫描。
#
# 用法：
#   bash check_console_residual.sh [--strict] [target_dir]
#
# --strict 模式：任何违规都以非零退出码退出

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RULES_DIR="${SCRIPT_DIR}/../ast-grep-rules"
source "${SCRIPT_DIR}/common.sh"
parse_guard_args "$@"

if ! command -v ast-grep >/dev/null 2>&1; then
  echo "[TS-03] SKIP: ast-grep 未安装（安装方法: brew install ast-grep）"
  exit 0
fi

# CLI 项目允许使用 console，跳过整个检查
_IS_CLI=false
if [[ -f "${TARGET_DIR}/package.json" ]]; then
  grep -qE '"bin"' "${TARGET_DIR}/package.json" 2>/dev/null && _IS_CLI=true
  grep -qE '"[^"]*":\s*"[^"]*cli[^"]*"' "${TARGET_DIR}/package.json" 2>/dev/null && _IS_CLI=true
fi
ls "${TARGET_DIR}/src/cli."* "${TARGET_DIR}/cli."* 2>/dev/null | grep -q . && _IS_CLI=true || true
if [[ "$_IS_CLI" == true ]]; then
  echo "[TS-03] SKIP: CLI 项目，console 为正常输出方式"
  exit 0
fi

RESULTS=$(create_tmpfile)

# AST 级别检测：仅匹配真实的 console 调用表达式，不匹配注释或字符串
#
# staged 模式：只扫 staged TS 文件，避免全仓扫描阻塞无关提交
if [[ -n "${VIBEGUARD_STAGED_FILES:-}" ]] && [[ -f "${VIBEGUARD_STAGED_FILES}" ]]; then
  mapfile -t _ASG_TARGETS < <(grep -E '\.(ts|tsx|js|jsx)$' "${VIBEGUARD_STAGED_FILES}" 2>/dev/null || true)
else
  _ASG_TARGETS=("${TARGET_DIR}")
fi

if [[ ${#_ASG_TARGETS[@]} -gt 0 ]]; then
ast-grep scan \
  --rule "${RULES_DIR}/ts-03-console.yml" \
  --json \
  "${_ASG_TARGETS[@]}" 2>/dev/null \
| python3 -c '
import json, sys, re

TEST_PATTERN = re.compile(r"(\.(test|spec)\.(ts|tsx|js|jsx)$|(^|/)tests/|(^|/)__tests__/|(^|/)test/|(^|/)vendor/)")
LOGGER_PATTERN = re.compile(r"(logger|logging|log\.config|/debug\.|/debug/)")
MCP_MARKERS = {"StdioServerTransport", "new Server(", "McpServer"}

mcp_cache = {}

def is_mcp(filepath):
    if filepath not in mcp_cache:
        try:
            with open(filepath, "r", errors="ignore") as fh:
                content = fh.read()
            mcp_cache[filepath] = any(m in content for m in MCP_MARKERS)
        except Exception:
            mcp_cache[filepath] = False
    return mcp_cache[filepath]

data = sys.stdin.read().strip()
if not data:
    sys.exit(0)
try:
    matches = json.loads(data)
except Exception:
    sys.exit(0)

for m in matches:
    f = m.get("file", "")
    if TEST_PATTERN.search(f):
        continue
    if LOGGER_PATTERN.search(f):
        continue
    if is_mcp(f):
        continue
    line = m.get("range", {}).get("start", {}).get("line", 0) + 1
    msg = m.get("message", "console 残留")
    print("[TS-03] " + f + ":" + str(line) + " " + msg)
' >> "$RESULTS" 2>/dev/null || true
fi

COUNT=$(wc -l < "$RESULTS" | tr -d ' ')

if [[ "$COUNT" -eq 0 ]]; then
  echo "[TS-03] PASS: 未检测到 console 残留"
  exit 0
fi

echo "[TS-03] 检测到 ${COUNT} 处 console 残留:"
echo
cat "$RESULTS"

if [[ "$STRICT" == "true" ]]; then
  exit 1
fi

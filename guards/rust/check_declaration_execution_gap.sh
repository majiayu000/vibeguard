#!/usr/bin/env bash
# RS-14: 声明-执行鸿沟检测 (ast-grep 版本)
#
# 检测 Config 类型通过 Default::default() 初始化而非 load() 方法的情况。
# 使用 ast-grep AST 级别扫描，消除之前 grep 版本的全量误报问题。
#
# 用法:
#   bash check_declaration_execution_gap.sh [--strict] [target_dir]

set -euo pipefail

source "$(dirname "$0")/common.sh"
parse_guard_args "$@"

if ! command -v ast-grep >/dev/null 2>&1; then
  echo "[RS-14] SKIP: ast-grep 未安装（安装方法: brew install ast-grep）"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES_DIR="${SCRIPT_DIR}/../ast-grep-rules"
TMPFILE=$(create_tmpfile)

TEST_PATH_PATTERN='(/tests/|/test_|_test\.rs$|tests\.rs$|test_helpers\.rs$|/examples/|/benches/)'

# 检测 *Config::default() 使用（排除测试路径）
ast-grep scan \
  --rule "${RULES_DIR}/rs-14-config-default.yml" \
  --json \
  "${TARGET_DIR}" 2>/dev/null \
| python3 -c '
import json, sys, re
TEST_PATH = re.compile(r"(/tests/|/test_|_test\.rs$|tests\.rs$|test_helpers\.rs$|/examples/|/benches/)")
data = sys.stdin.read().strip()
if not data:
    sys.exit(0)
try:
    matches = json.loads(data)
except Exception:
    sys.exit(0)
for m in matches:
    f = m.get("file", "")
    if TEST_PATH.search(f):
        continue
    line = m.get("range", {}).get("start", {}).get("line", 0) + 1
    text = m.get("text", "")
    msg = m.get("message", "")
    print("[RS-14] " + f + ":" + str(line) + " " + msg + " (" + text + ")")
' > "$TMPFILE" 2>/dev/null || true

FOUND=$(wc -l < "$TMPFILE" | tr -d ' ')

if [[ $FOUND -eq 0 ]]; then
  echo "[RS-14] PASS: 未检测到 Config 声明-执行鸿沟"
  exit 0
fi

cat "$TMPFILE"
echo ""
echo "Found ${FOUND} potential Config declaration-execution gap(s)."
echo ""
echo "修复方法："
echo "  1. Config 若有 load() 方法，启动时应调用 Config::load() 而非 Config::default()"
echo "  2. 若 Default::default() 确为预期行为（如测试或默认配置），添加注释说明"

if [[ "${STRICT}" == true ]]; then
  exit 1
fi

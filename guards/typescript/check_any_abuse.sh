#!/usr/bin/env bash
# VibeGuard TypeScript Guard — [TS-01] any 类型滥用检测
#
# 使用 ast-grep 做 AST 级别检测，消除注释/字符串误报。
# 检测非测试文件中的 `as any`、`: any`、`@ts-ignore`、`@ts-nocheck`。
#
# 用法：
#   bash check_any_abuse.sh [--strict] [target_dir]
#
# --strict 模式：任何违规都以非零退出码退出

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RULES_DIR="${SCRIPT_DIR}/../ast-grep-rules"
source "${SCRIPT_DIR}/common.sh"
parse_guard_args "$@"

if ! command -v ast-grep >/dev/null 2>&1; then
  echo "[TS-01] SKIP: ast-grep 未安装（安装方法: brew install ast-grep）"
  exit 0
fi

RESULTS=$(create_tmpfile)

# --- AST 级别检测: as any 和 : any 类型注解 ---
# ast-grep 仅匹配代码节点，自动跳过注释和字符串中的误报
#
# staged 模式：只扫 staged TS 文件，避免全仓扫描阻塞无关提交
if [[ -n "${VIBEGUARD_STAGED_FILES:-}" ]] && [[ -f "${VIBEGUARD_STAGED_FILES}" ]]; then
  mapfile -t _ASG_TARGETS < <(grep -E '\.(ts|tsx|js|jsx)$' "${VIBEGUARD_STAGED_FILES}" 2>/dev/null || true)
else
  _ASG_TARGETS=("${TARGET_DIR}")
fi

if [[ ${#_ASG_TARGETS[@]} -gt 0 ]]; then
ast-grep scan \
  --rule "${RULES_DIR}/ts-01-any.yml" \
  --json \
  "${_ASG_TARGETS[@]}" 2>/dev/null \
| python3 -c '
import json, sys, re
TEST_PATTERN = re.compile(r"(\.(test|spec)\.(ts|tsx|js|jsx)$|(^|/)tests/|(^|/)__tests__/|(^|/)test/|(^|/)vendor/)")
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
    line = m.get("range", {}).get("start", {}).get("line", 0) + 1
    msg = m.get("message", "any 类型使用")
    print("[TS-01] " + f + ":" + str(line) + " " + msg)
' >> "$RESULTS" 2>/dev/null || true
fi

# --- grep 检测: @ts-ignore 和 @ts-nocheck（注释指令，grep 精度已足够）---
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  [[ ! -f "$file" ]] && continue

  REL_PATH="${file#${TARGET_DIR}/}"

  while IFS= read -r line_info; do
    [[ -z "$line_info" ]] && continue
    LINE_NUM=$(echo "$line_info" | cut -d: -f1)
    echo "[TS-01] ${REL_PATH}:${LINE_NUM} '@ts-ignore' 禁用类型检查。修复：修复类型错误而非忽略" >> "$RESULTS"
  done < <(grep -n '@ts-ignore' "$file" 2>/dev/null || true)

  while IFS= read -r line_info; do
    [[ -z "$line_info" ]] && continue
    LINE_NUM=$(echo "$line_info" | cut -d: -f1)
    echo "[TS-01] ${REL_PATH}:${LINE_NUM} '@ts-nocheck' 禁用整个文件类型检查。修复：逐个修复类型错误" >> "$RESULTS"
  done < <(grep -n '@ts-nocheck' "$file" 2>/dev/null || true)

done < <(list_ts_files "$TARGET_DIR" | filter_non_test)

COUNT=$(wc -l < "$RESULTS" | tr -d ' ')

if [[ "$COUNT" -eq 0 ]]; then
  echo "[TS-01] PASS: 未检测到 any 类型滥用"
  exit 0
fi

echo "[TS-01] 检测到 ${COUNT} 处 any 类型滥用:"
cat "$RESULTS"

if [[ "$STRICT" == "true" ]]; then
  exit 1
fi

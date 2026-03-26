#!/usr/bin/env bash
# VibeGuard TypeScript Guard — [TS-01] any 类型滥用检测 / [TS-02] ts-ignore 检测
#
# 使用 ast-grep 做 AST 级别检测，消除注释/字符串误报。
# ast-grep 不可用时，回退到 grep 检测。
# 检测非测试文件中的 `as any`、`: any`（TS-01）和 `@ts-ignore`、`@ts-nocheck`（TS-02）。
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

RESULTS=$(create_tmpfile)

# --- TS-01: as any 和 : any 类型注解 ---
_USE_GREP_FALLBACK=false

if command -v ast-grep >/dev/null 2>&1; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "[TS-01] WARN: python3 不可用，使用 grep fallback" >&2
    _USE_GREP_FALLBACK=true
  else
    # staged 模式：只扫 staged TS 文件，避免全仓扫描阻塞无关提交
    if [[ -n "${VIBEGUARD_STAGED_FILES:-}" ]] && [[ -f "${VIBEGUARD_STAGED_FILES}" ]]; then
      mapfile -t _ASG_TARGETS < <(grep -E '\.(ts|tsx|js|jsx)$' "${VIBEGUARD_STAGED_FILES}" 2>/dev/null || true)
    else
      _ASG_TARGETS=("${TARGET_DIR}")
    fi

    if [[ ${#_ASG_TARGETS[@]} -gt 0 ]]; then
      _ASG_TMPOUT=$(create_tmpfile)
      if ast-grep scan \
          --rule "${RULES_DIR}/ts-01-any.yml" \
          --json \
          "${_ASG_TARGETS[@]}" > "${_ASG_TMPOUT}"; then
        python3 -c '
import json, sys, re
TEST_PATTERN = re.compile(r"(\.(test|spec)\.(ts|tsx|js|jsx)$|(^|/)tests/|(^|/)__tests__/|(^|/)test/|(^|/)vendor/)")
data = sys.stdin.read().strip()
if not data:
    sys.exit(0)
try:
    matches = json.loads(data)
except Exception as e:
    print("[TS-01] WARN: ast-grep JSON 解析失败: " + str(e), file=sys.stderr)
    sys.exit(1)
for m in matches:
    f = m.get("file", "")
    if TEST_PATTERN.search(f):
        continue
    line = m.get("range", {}).get("start", {}).get("line", 0) + 1
    msg = m.get("message", "any 类型使用")
    print("[TS-01] " + f + ":" + str(line) + " " + msg)
' < "${_ASG_TMPOUT}" >> "$RESULTS" || {
          echo "[TS-01] WARN: python3 处理失败，使用 grep fallback" >&2
          _USE_GREP_FALLBACK=true
        }
      else
        echo "[TS-01] WARN: ast-grep 扫描失败（规则文件可能缺失），使用 grep fallback" >&2
        _USE_GREP_FALLBACK=true
      fi
    fi
  fi
else
  _USE_GREP_FALLBACK=true
fi

if [[ "$_USE_GREP_FALLBACK" == true ]]; then
  list_ts_files "${TARGET_DIR}" \
    | filter_non_test \
    | while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        grep -nE '(:\s*any\b|\bas\s+any\b)' "$f" 2>/dev/null \
          | grep -v '^\s*//' \
          | while IFS= read -r line_info; do
              LINE_NUM=$(echo "$line_info" | cut -d: -f1)
              echo "[TS-01] ${f}:${LINE_NUM} any 类型使用（grep fallback）"
            done
      done >> "$RESULTS" || true
fi

# --- TS-02: @ts-ignore 和 @ts-nocheck（注释指令，grep 精度已足够）---
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  [[ ! -f "$file" ]] && continue

  REL_PATH="${file#${TARGET_DIR}/}"

  while IFS= read -r line_info; do
    [[ -z "$line_info" ]] && continue
    LINE_NUM=$(echo "$line_info" | cut -d: -f1)
    echo "[TS-02] ${REL_PATH}:${LINE_NUM} '@ts-ignore' 禁用类型检查。修复：修复类型错误而非忽略" >> "$RESULTS"
  done < <(grep -n '@ts-ignore' "$file" 2>/dev/null || true)

  while IFS= read -r line_info; do
    [[ -z "$line_info" ]] && continue
    LINE_NUM=$(echo "$line_info" | cut -d: -f1)
    echo "[TS-02] ${REL_PATH}:${LINE_NUM} '@ts-nocheck' 禁用整个文件类型检查。修复：逐个修复类型错误" >> "$RESULTS"
  done < <(grep -n '@ts-nocheck' "$file" 2>/dev/null || true)

done < <(list_ts_files "$TARGET_DIR" | filter_non_test)

apply_suppression_filter "$RESULTS"
COUNT_01=$(grep -cE '^\[TS-01\]' "$RESULTS" || true)
COUNT_02=$(grep -cE '^\[TS-02\]' "$RESULTS" || true)
COUNT=$((COUNT_01 + COUNT_02))

if [[ "$COUNT" -eq 0 ]]; then
  echo "[TS-01] PASS: 未检测到 any 类型滥用"
  exit 0
fi

if [[ "$COUNT_01" -gt 0 ]]; then
  echo "[TS-01] 检测到 ${COUNT_01} 处 any 类型问题:"
  grep -E '^\[TS-01\]' "$RESULTS"
fi

if [[ "$COUNT_02" -gt 0 ]]; then
  echo "[TS-02] 检测到 ${COUNT_02} 处 ts-ignore/ts-nocheck 问题:"
  grep -E '^\[TS-02\]' "$RESULTS"
fi

if [[ "$STRICT" == "true" ]]; then
  exit 1
fi

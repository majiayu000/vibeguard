#!/usr/bin/env bash
# VibeGuard Go Guard: 检测未检查的 error 返回值 (GO-01)
#
# 使用 ast-grep AST 级别扫描，精确识别 `_ = func()` 赋值语句。
# ast-grep 自动区分代码结构，不会误报 for range 子句中的 _ 变量。
#
# 用法:
#   bash check_error_handling.sh [target_dir]
#   bash check_error_handling.sh --strict [target_dir]
#
# 排除:
#   - *_test.go 测试文件
#   - vendor/ 目录

source "$(dirname "$0")/common.sh"
parse_guard_args "$@"
TMPFILE=$(create_tmpfile)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RULES_DIR="${SCRIPT_DIR}/../ast-grep-rules"

if command -v ast-grep >/dev/null 2>&1; then
  # AST 级别检测：仅匹配真实的 _ = expr 赋值，不匹配 for range 子句
  #
  # staged 模式：只扫 staged Go 文件，避免全仓扫描阻塞无关提交
  if [[ -n "${VIBEGUARD_STAGED_FILES:-}" ]] && [[ -f "${VIBEGUARD_STAGED_FILES}" ]]; then
    mapfile -t _ASG_TARGETS < <(grep -E '\.go$' "${VIBEGUARD_STAGED_FILES}" 2>/dev/null || true)
  else
    _ASG_TARGETS=("${TARGET_DIR}")
  fi

  if [[ ${#_ASG_TARGETS[@]} -gt 0 ]]; then
  ast-grep scan \
    --rule "${RULES_DIR}/go-01-error.yml" \
    --json \
    "${_ASG_TARGETS[@]}" 2>/dev/null \
  | python3 -c '
import json, sys, re
TEST_PATH = re.compile(r"(_test\.go$|(^|/)vendor/)")
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
    msg = m.get("message", "error 返回值被丢弃")
    print("[GO-01] " + f + ":" + str(line) + " " + msg)
' > "${TMPFILE}" || true
  fi

else
  # Fallback: grep（ast-grep 不可用）
  list_go_files "${TARGET_DIR}" \
    | { grep -vE '(_test\.go$|/vendor/)' || true; } \
    | while IFS= read -r f; do
        if [[ -f "${f}" ]]; then
          grep -nE '^\s*_\s*(,\s*_)?\s*[:=]+' "${f}" 2>/dev/null \
            | grep -vE 'for\s+.*range' \
            | grep -vE ',\s*(ok|found|exists)\s*:?=' \
            | sed "s|^|${f}:|" || true
        fi
      done \
    | grep -v '^\s*//' \
    | awk '!/^[[:space:]]*\/\// { print "[GO-01] " $0 }' \
    > "${TMPFILE}" || true
fi

cat "${TMPFILE}"
FOUND=$(wc -l < "${TMPFILE}" | tr -d ' ')

echo ""
if [[ ${FOUND} -eq 0 ]]; then
  echo "No unchecked error returns found."
else
  echo "Found ${FOUND} unchecked error return(s)."
  echo ""
  echo "修复方法："
  echo "  1. _ = fn() → err := fn(); if err != nil { return fmt.Errorf(\"context: %w\", err) }"
  echo "  2. 确实不需要错误 → 添加注释说明原因"
  echo "  3. defer 场景 → defer func() { _ = f.Close() }() 可接受，但建议记录日志"
  if [[ "${STRICT}" == true ]]; then
    exit 1
  fi
fi

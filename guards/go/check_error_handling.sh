#!/usr/bin/env bash
# VibeGuard Go Guard: 检测未检查的 error 返回值 (GO-01)
#
# 扫描 Go 代码中赋值给 _ 的 error 返回值。
# 用法:
#   bash check_error_handling.sh [target_dir]
#   bash check_error_handling.sh --strict [target_dir]
#
# 排除:
#   - *_test.go 测试文件
#   - vendor/ 目录
#   - 注释行

source "$(dirname "$0")/common.sh"
parse_guard_args "$@"
TMPFILE=$(create_tmpfile)

list_go_files "${TARGET_DIR}" \
  | { grep -vE '(_test\.go$|/vendor/)' || true; } \
  | while IFS= read -r f; do
      if [[ -f "${f}" ]]; then
        # 检测 _ = someFunc() 中直接丢弃 error
        # 排除：for _, v := range（range 变量）、_, ok := m[key]（map 查找）
        grep -nE '^\s*_\s*(,\s*_)?\s*[:=]+' "${f}" 2>/dev/null \
          | grep -vE 'for\s+.*range' \
          | grep -vE ',\s*(ok|found|exists)\s*:?=' \
          | sed "s|^|${f}:|" || true
      fi
    done \
  | grep -v '^\s*//' \
  | awk '!/^[[:space:]]*\/\// { print "[GO-01] " $0 }' \
  > "${TMPFILE}" || true

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

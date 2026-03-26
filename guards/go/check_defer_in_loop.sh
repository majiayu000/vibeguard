#!/usr/bin/env bash
# VibeGuard Go Guard: 检测循环内 defer (GO-08)
#
# defer 在循环内不会在每次迭代结束时执行，而是在函数返回时执行。
# 这会导致资源泄漏（文件句柄、数据库连接等在循环结束前不会释放）。
#
# 用法:
#   bash check_defer_in_loop.sh [target_dir]
#   bash check_defer_in_loop.sh --strict [target_dir]
#
# 排除:
#   - *_test.go 测试文件
#   - vendor/ 目录

source "$(dirname "$0")/common.sh"
parse_guard_args "$@"
TMPFILE=$(create_tmpfile)

# --- Baseline/diff 过滤：只报告新增行上的问题（pre-commit 或 --baseline 模式）---
_LINEMAP=""
if [[ -n "${VIBEGUARD_STAGED_FILES:-}" ]] || [[ -n "${BASELINE_COMMIT:-}" ]]; then
  _LINEMAP=$(create_tmpfile)
  vg_build_diff_linemap "$_LINEMAP" '\.go$' || _LINEMAP=""
fi

# 使用 awk 检测 for 循环内的 defer，再对结果做 linemap 过滤
_AWK_RAW=$(create_tmpfile)
list_go_files "${TARGET_DIR}" \
  | { grep -vE '(_test\.go$|/vendor/)' || true; } \
  | while IFS= read -r f; do
      if [[ -f "${f}" ]]; then
        awk '
          /^\s*for\s/ { in_loop++; loop_depth++ }
          /\{/ { if (in_loop) brace_depth++ }
          /\}/ { if (in_loop) { brace_depth--; if (brace_depth <= 0) { in_loop=0; loop_depth--; brace_depth=0 } } }
          /^\s*defer\s/ && in_loop > 0 {
            printf "[GO-08] %s:%d %s\n", FILENAME, NR, $0
          }
        ' "${f}" 2>/dev/null || true
      fi
    done \
  > "${_AWK_RAW}" || true

# Linemap 过滤：提取 file:linenum，只保留新增行
if [[ -n "$_LINEMAP" ]] && [[ -s "$_LINEMAP" ]]; then
  while IFS= read -r result_line; do
    [[ -z "$result_line" ]] && continue
    # 格式: [GO-08] /path/to/file:LINENUM content
    # 提取 filepath 和 linenum（linenum 是紧跟 : 后的第一个数字序列）
    stripped="${result_line#\[GO-08\] }"
    # 反向查找最后一个冒号前的数字序列作为 linenum
    linenum=$(echo "$stripped" | grep -oE ':[0-9]+' | tail -1 | tr -d ':')
    filepath=$(echo "$stripped" | sed "s/:${linenum} .*$//")
    if [[ -n "$linenum" ]] && grep -qxF "${filepath}:${linenum}" "$_LINEMAP" 2>/dev/null; then
      echo "$result_line"
    fi
  done < "${_AWK_RAW}" > "${TMPFILE}" || true
else
  cp "${_AWK_RAW}" "${TMPFILE}" || true
fi

apply_suppression_filter "${TMPFILE}"
cat "${TMPFILE}"
FOUND=$(wc -l < "${TMPFILE}" | tr -d ' ')

echo ""
if [[ ${FOUND} -eq 0 ]]; then
  echo "No defer-in-loop issues found."
else
  echo "Found ${FOUND} defer-in-loop issue(s)."
  echo ""
  echo "修复方法："
  echo "  1. 将 defer 所在逻辑提取为独立函数："
  echo "     for _, item := range items {"
  echo "         if err := processItem(item); err != nil { ... }"
  echo "     }"
  echo "     func processItem(item Item) error {"
  echo "         f, err := os.Open(item.Path)"
  echo "         if err != nil { return err }"
  echo "         defer f.Close()  // 在函数结束时正确释放"
  echo "         ..."
  echo "     }"
  echo "  2. 手动在每次迭代末尾关闭资源（不推荐，容易遗漏）"
  if [[ "${STRICT}" == true ]]; then
    exit 1
  fi
fi
